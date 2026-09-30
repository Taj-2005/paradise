# Mac 2 — Edge reverse proxy, load balancer, TLS terminator

**Role:** the single entry point. Every client request in this project arrives here.
**Cloud equivalent:** an AWS Application Load Balancer with an ACM certificate on its HTTPS listener.
**Spec:** Tasks D and E (10 of the 40 team marks).

## What happens on this machine

```
client ──TLS──▶ nginx :443 ──plaintext HTTP──▶ Mac 3 :3001  (Backend A)
                    │                     └──▶ Mac 4 :3002  (Backend B)
                    │
                TLS terminates here
```

Three separate jobs, all in `conf.d/site.conf`:

1. **TLS termination** — decrypt the client's HTTPS, so the backends never
   handle certificates. Exactly what an ALB does.
2. **Reverse proxying** — forward the decrypted request to an upstream, adding
   `X-Forwarded-For` / `X-Forwarded-Proto` so the backend can still tell what
   the client originally asked for.
3. **Load balancing** — round-robin across the two backends, with passive
   health checks so a dead backend is taken out of rotation.

## Run

```bash
make edge                             # certs + config + validate + start
./infra/mac2-edge/scripts/verify.sh   # prove it works
```

## The client/edge and edge/backend legs are different connections

This is the most useful thing to understand here, and a likely viva question.

| | client → edge | edge → backend |
|---|---|---|
| Protocol | HTTPS (TLS 1.2/1.3) | plain HTTP/1.1 |
| Port | 443 (or 8443) | 3001 / 3002 |
| TCP session | client ephemeral port → 443 | nginx ephemeral port → 3001 |
| Readable in Wireshark? | **No** — encrypted | **Yes** — plaintext |

They are two independent TCP connections with two independent handshakes. The
client's TLS session ends at nginx. That is why a capture on Mac 2 shows
unreadable Application Data on one side and fully readable HTTP headers on the
other — a very strong thing to point at on camera.

## Why the client never learns the backend IPs

DNS returns only Mac 2's address, and nginx is the only thing the client ever
connects to. The backends could be renumbered, moved, or scaled to ten machines
and the client would never notice. That indirection is the entire value of a
reverse proxy, and it is what makes Phase 2's service isolation possible: the
backends can be firewalled so that *only* Mac 2 can reach them.

## Requests by IP are rejected on purpose

`nginx.conf` has a `default_server` that returns `444` (close without
responding). A request that arrives by IP has no matching `server_name` and
lands there:

```bash
curl -k https://<edge-ip>/          # empty reply — refused
curl    https://app.paradise.test/  # 200
```

Same machine, same port. Only the SNI/Host differs. This enforces the spec's
"access by domain name, never by IP" rule at the server rather than on trust.

## A note on HTTP/2 and header case

`http2 on` is enabled, so curl negotiates HTTP/2 over TLS. **HTTP/2 requires
all header names to be lowercase**, so your evidence will read `etag:` and
`x-backend:` rather than `ETag:` and `X-Backend:`. That is correct and costs
nothing — but if you want HTTP/1.1-style output for a screenshot:

```bash
curl --http1.1 -sI https://app.paradise.test/api/status
```

## Files

| Path | Committed | Notes |
|---|---|---|
| `nginx/nginx.conf.template` | yes | Main config; log format, default_server |
| `nginx/conf.d/site.conf.template` | yes | Upstream pool, TLS, proxy rules |
| `nginx/*.conf` | no | Rendered from `.env` — regenerate, never edit |
| `certs/` | no | See `certs/README.md` |

## Restore

```bash
sudo nginx -s stop
cp /opt/homebrew/etc/nginx/nginx.conf.orig /opt/homebrew/etc/nginx/nginx.conf
```

## Phase 2 hooks (do not build yet)

- **Extension D — HA failover:** `max_fails`/`fail_timeout` are already in the
  upstream block; add active health checks against `/healthz`.
- **Extension E — edge migration:** stand up this same config on another Mac,
  then repoint the DNS A record and watch TTL govern the cutover.
- **Single point of failure:** this machine. Naming that in the viva scores
  marks (spec Extension D explicitly asks for it).
