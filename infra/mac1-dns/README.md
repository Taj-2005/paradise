# Mac 1 — Private DNS server

**Role:** authoritative resolver for `*.paradise.test`, forwarder for everything else.
**Cloud equivalent:** an AWS Route 53 *private hosted zone*.
**Spec:** Task B.

## What this machine answers

| Name | Type | Answer | Why |
|---|---|---|---|
| `app.paradise.test` | A | Mac 2's IP | The edge is the only entry point |
| `api.paradise.test` | A | Mac 2's IP | Same edge, different hostname |
| anything else | — | forwarded upstream | So clients keep normal internet |

Both names resolve to the **edge**, never to a backend. That is the point of a
reverse proxy: the client cannot address Mac 3 or Mac 4 even if it wanted to,
because it was never told they exist.

## Run

```bash
make dns          # render config, install, validate, start, self-test
./infra/mac1-dns/verify.sh
```

`install.sh` is idempotent — re-run it after any `.env` change.

## The two lines that decide whether this works

```conf
listen-address=0.0.0.0     # NOT 127.0.0.1
interface=en0
```

With the dnsmasq default of `127.0.0.1`, everything you test *on Mac 1* passes
and every other laptop times out. `install.sh` hard-fails if it finds loopback
here, because the symptom is so misleading.

## Showing it work on camera

```bash
sudo tail -f /opt/homebrew/var/log/dnsmasq.log
```

Leave this running on Mac 1 and `dig app.paradise.test` on Mac 3 — the query
appears in the log the instant it is made. That is live proof the client's
resolution reached *this* server and not the router or 8.8.8.8.

## Restore

```bash
sudo brew services stop dnsmasq
sudo cp /opt/homebrew/etc/dnsmasq.conf.orig /opt/homebrew/etc/dnsmasq.conf
```

`install.sh` saves that `.orig` backup the first time it runs.

## Phase 2 hooks (do not build yet)

- **Extension A — backup resolver:** same config on a second Mac; clients list both.
- **Extension B — TTL:** set `DNS_TTL=30` in `.env`, re-render, restart. Change a
  record and watch clients keep the stale answer until the TTL expires.
