# Troubleshooting

## Diagnose top down — always in this order

The point of the layered model is that you can bisect a failure. Work down;
**the first step that fails names the layer**, and everything below it is fine.

```bash
# 1 · Link / network — is the machine reachable at all?
ping -c3 <edge-ip>

# 2 · Application (DNS) — does the name resolve, and who answered?
dig app.paradise.test

# 3 · Transport — is anything listening on that port?
nc -vz app.paradise.test 443

# 4 · Session/Presentation — does TLS complete and validate?
curl -v https://app.paradise.test/api/status 2>&1 | grep -i 'ssl\|certificate'

# 5 · Application (HTTP) — what did the service actually say?
curl -i https://app.paradise.test/api/status
```

`./scripts/status.sh` runs all five and prints a verdict.

This sequence is also the answer to the Phase 2 faculty-injected fault
(Extension F) — say it out loud while you do it; methodology earns partial
credit even if the fix is incomplete.

## Symptom → layer → fix

| Symptom | Layer | Likely cause | Fix |
|---|---|---|---|
| `ping` fails between machines | network | Different Wi-Fi / AP client isolation | Same SSID; disable client isolation on the router |
| `dig` times out from a client | application (DNS) | dnsmasq on `127.0.0.1` | `listen-address=0.0.0.0` + `interface=en0`, `make dns` |
| `dig` works on Mac 1, not elsewhere | application (DNS) | Same as above | Same |
| `dig` returns NXDOMAIN for your own name | application (DNS) | Client not using Mac 1 | `make client-dns`; check the `SERVER:` line |
| Client lost internet after `client-dns` | application (DNS) | dnsmasq not forwarding | `no-resolv` + `server=1.1.1.1` in `dnsmasq.conf` |
| Name resolves to the wrong IP | application (DNS) | Stale cache or stale `address=` line | `sudo dscacheutil -flushcache`; re-render |
| `Connection refused` on 443 | transport | nginx not running, or wrong port | `sudo nginx -t && sudo nginx`; check `HTTPS_PORT` |
| `Connection refused` only from other Macs | transport | macOS firewall | System Settings → Network → Firewall → allow nginx |
| `curl: (60)` cert not trusted | session | CA not in this Mac's keychain | `make client-trust` |
| `curl: (60)` no alternative subject name | session | Cert has CN but no SAN | Re-run `gen-certs.sh`; it enforces SAN |
| Cert was fine, now untrusted | session | Cert regenerated → new CA | Redistribute `rootCA.pem`, re-run `client-trust` everywhere |
| Empty reply from server | application | Requested by IP → `default_server` 444 | Use the domain name |
| **502 Bad Gateway** | application | Backends down or loopback-bound | See below |
| `X-Backend` never changes | application | One backend down | `./scripts/status.sh` on both backends |
| 304 sometimes, 200 other times | application | Per-replica ETag on `/api/status` | Use `/api/cacheable` — see below |
| `EADDRINUSE` starting a backend | transport | Old process still holds the port | `lsof -nP -iTCP:3001 -sTCP:LISTEN` then `kill <pid>` |

## The three that actually bite

### 502 Bad Gateway

nginx is healthy; it cannot reach an upstream. Confirm from **Mac 2**, not
from the backend itself:

```bash
curl -v http://<backend-ip>:3001/healthz
```

- **Connection refused** → the backend is not running, or it is bound to
  `127.0.0.1`. On the backend: `lsof -nP -iTCP:3001 -sTCP:LISTEN`.
  You want `TCP *:3001`, **not** `TCP 127.0.0.1:3001`.
- **Timeout** → macOS firewall on the backend. Allow `node`.
- **Works from Mac 2 but 502 through the proxy** → wrong IP in the upstream
  block. Re-render after fixing `.env`.

Loopback binding is the most common single failure in this project, because
the backend looks perfectly healthy when tested on its own laptop.
`src/config.js` now refuses to start on loopback for exactly this reason.

### Certificate not trusted — and why you must not reach for `-k`

`-k` in submitted evidence scores **zero** for the HTTPS section. Fix the trust
instead:

```bash
make client-trust        # on every Mac, including Mac 2
```

Then confirm:

```bash
curl -v https://app.paradise.test/api/status 2>&1 | grep -i 'verify\|subject\|issuer'
# want: SSL certificate verify ok.
```

If it still fails, the cert nginx is serving was not signed by the CA this
machine trusts. Regenerating the certificate creates a **new CA** — redistribute
`rootCA.pem` and re-trust everywhere.

### Intermittent 304

If a conditional request returns 304 sometimes and 200 other times, you are
testing `/api/status`. Its body contains the backend identifier, so Backend A
and Backend B compute **different ETags**. With round robin your conditional
request often lands on the other replica, which sees a validator it does not
recognise and sends a full 200.

Use `/api/cacheable`, whose body is byte-identical on both backends:

```bash
ETAG=$(curl -sI https://app.paradise.test/api/cacheable | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '\r')
curl -sI -H "If-None-Match: $ETAG" https://app.paradise.test/api/cacheable
```

This is a genuine constraint on caching behind a load balancer, worth saying in
the viva: **validators must agree across replicas, or conditional requests
silently degrade to full responses.**

## Things that look broken but are not

| Observation | Why it is correct |
|---|---|
| Header names lowercase (`etag:`, `x-backend:`) | HTTP/2 requires it. Use `curl --http1.1` for classic casing. |
| Wireshark shows only "Application Data" | TLS is working. That is the point. |
| `dig @8.8.8.8` returns NXDOMAIN | Required — it proves the name is private (form A4). |
| `curl https://<ip>/` gives an empty reply | `default_server` returns 444 on purpose. |
| `X-Backend` alternates but not perfectly | Keepalive pooling can skew short bursts. Both appearing in six requests is what matters. |
| First request slower than the rest | Full TLS handshake; later ones resume the session. |

## Reset everything

```bash
make restore     # on each machine — idempotent
make verify      # from a client
```

Full teardown is in [runbook.md](runbook.md#shutting-down-cleanly).
