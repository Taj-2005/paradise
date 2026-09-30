# Mac 4 — Backend B

**Role:** one of two interchangeable application servers behind the edge.
**Cloud equivalent:** an EC2 instance registered in an ALB target group.
**Spec:** Task C.
**Listens on:** `0.0.0.0:3002`

## Run

```bash
make backend-b
```

Leave it in the foreground. The access log it prints is worth having on screen
during the demo — you can watch requests land here in real time as the load
balancer alternates.

## Same code as Backend A

Nothing in `services/backend/` knows which machine it is on. This instance is
Backend B only because `run.sh` starts it with `BACKEND_ID=B PORT=3002`.
That is deliberate: two identical replicas behind a load balancer is the point
of the exercise, and it means a fix only has to be made once.

## Bound to 0.0.0.0, never 127.0.0.1

The service **refuses to start** on loopback. Binding to `127.0.0.1` makes it
reachable from this laptop and invisible to nginx on Mac 2, so every request
through the load balancer returns 502 while `curl localhost:3002` looks
perfectly healthy. Spec §6 Task C forbids it; `src/config.js` enforces it.

Confirm what you are actually bound to:

```bash
lsof -nP -iTCP:3002 -sTCP:LISTEN
# want:  TCP *:3002 (LISTEN)
# NOT:   TCP 127.0.0.1:3002 (LISTEN)
```

## Endpoints

| Path | Cache-Control | Notes |
|---|---|---|
| `/` | `max-age=60` | HTML in a browser, JSON to curl |
| `/api/status` | `max-age=60` + ETag | Body identifies this backend |
| `/api/cacheable` | `max-age=60` + ETag | Body identical on both replicas — used for the 304 demo |
| `/healthz` | `no-store` | nginx health probe |
| `/api/time` | `no-store` | Contrast case for the caching explanation |

Every response carries `X-Backend: B`.

## Stopping this is the failure demo

Spec §6.3 Option A. Press Ctrl-C here and all traffic shifts to the other
backend within one request — nginx marks this server down after a single
connection failure (`max_fails=1`). Restart and round-robin resumes.

Run it scripted with `make demo-fail`, which captures before/after evidence
and restores automatically.
