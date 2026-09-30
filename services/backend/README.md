# Backend service

One codebase. Two running instances. The **only** difference between Backend A
and Backend B is the environment they are started with — there is no per-machine
code fork, because the network is the project, not the app.

| | Mac 3 | Mac 4 |
|---|---|---|
| `BACKEND_ID` | `A` | `B` |
| `PORT` | `3001` | `3002` |
| `HOST` | `0.0.0.0` | `0.0.0.0` |

## Endpoints

| Method | Path | Cache-Control | Purpose |
|---|---|---|---|
| GET | `/` | `public, max-age=60` | Service-alive page. JSON for curl, HTML for a browser. |
| GET | `/api/status` | `public, max-age=60` + `ETag` | Task C/D/F. The endpoint the whole demo uses. |
| GET | `/healthz` | `no-store` | Liveness probe for nginx. |
| GET | `/api/time` | `no-store` | Contrast case for the caching explanation. |

Every response — including 304s and 404s — carries `X-Backend: A|B`.
That header is what makes load balancing visible.

## Two design decisions worth knowing for the viva

**1. `/api/status` has a stable body.**
It reports `startedAt` (fixed for the life of the process), never `now` or
`uptime`. If the body changed on every request the ETag would change too, and a
conditional request could *never* return 304 — the Task F demo would be
impossible. Volatile values live on `/api/time`, which is `no-store`.

**2. The server refuses to start on loopback.**
`HOST=127.0.0.1` exits with an error instead of starting. Binding to loopback is
the single most common way this project breaks: the service looks fine from its
own laptop, but nginx on Mac 2 gets `ECONNREFUSED` and every request through the
load balancer returns **502 Bad Gateway**. Spec §6 Task C forbids it explicitly.

## Run

```bash
npm install                                     # once, on each backend machine
BACKEND_ID=A PORT=3001 HOST=0.0.0.0 npm start   # Mac 3
BACKEND_ID=B PORT=3002 HOST=0.0.0.0 npm start   # Mac 4
```

In practice use the wrappers, which read `.env` and set all of this for you:

```bash
make backend-a    # on Mac 3
make backend-b    # on Mac 4
```

## Test

```bash
npm test
```

Eight checks covering the response contract that `nginx.conf` and the evaluator
depend on. These use `node:http`, not `fetch()` — `fetch` is a caching client
and silently replays a 304 as a 200 from its own cache, so it cannot observe the
behaviour Task F asks you to demonstrate. `curl` and `node:http` show the real
status line.
