# Runbook

Exact boot order and commands for all four machines. Follow it top to bottom
the first time; after that `make restore` on each machine is usually enough.

## Before you start

- All four Macs on the **same** Wi-Fi/LAN.
- Homebrew on every machine.
- Admin (sudo) on **Mac 1** and **Mac 2** at minimum.
- The repo cloned on every machine.

## Step 0 · Fill in `.env` (once, then copy to all four)

On any machine, get its address:

```bash
ipconfig getifaddr en0
```

Collect all four, then edit `.env` at the repo root:

```bash
cp .env.example .env
$EDITOR .env          # set DNS_IP, EDGE_IP, BACKEND_A_IP, BACKEND_B_IP
./scripts/render-configs.sh
```

Copy the same `.env` to the other three machines — it is the single source of
truth and they must agree.

```bash
scp .env <user>@<mac2>:~/cn-phase1-paradise/.env
```

> If `ipconfig getifaddr en0` prints nothing, your LAN is not on `en0`.
> Find it with `route get default | awk '/interface:/{print $2}'` and set
> `IFACE` in `.env`.

## Step 1 · Mac 3 and Mac 4 — backends first

Backends first so that when nginx starts it has somewhere to send traffic.

```bash
# Mac 3
./scripts/bootstrap.sh
make backend-a          # leave running in the foreground

# Mac 4
./scripts/bootstrap.sh
make backend-b          # leave running in the foreground
```

Confirm each is on `0.0.0.0` and not loopback:

```bash
lsof -nP -iTCP:3001 -sTCP:LISTEN     # want  TCP *:3001   NOT  TCP 127.0.0.1:3001
```

## Step 2 · Mac 2 — the edge

```bash
./scripts/bootstrap.sh          # installs nginx, mkcert
make edge                       # certs + config + validate + start
```

This generates the certificate, installs `nginx.conf` and `conf.d/site.conf`,
runs `nginx -t`, starts nginx, and self-tests end to end.

Distribute the CA so nobody ever needs `-k`:

```bash
scp infra/mac2-edge/certs/rootCA.pem <user>@<mac1>:~/
scp infra/mac2-edge/certs/rootCA.pem <user>@<mac3>:~/
scp infra/mac2-edge/certs/rootCA.pem <user>@<mac4>:~/
```

## Step 3 · Mac 1 — DNS

```bash
./scripts/bootstrap.sh
make dns
./infra/mac1-dns/verify.sh
```

## Step 4 · Every machine — point at the DNS and trust the CA

On **all four**, including Mac 1 and Mac 2:

```bash
make client-dns         # resolver -> Mac 1
make client-trust       # root CA -> System keychain
```

`client-trust` finishes by proving the certificate validates **without `-k`**.
If it cannot, stop and fix it here — do not discover it while recording.

## Step 5 · Verify

From a **client** machine (Mac 1, 3 or 4 — not Mac 2):

```bash
make preflight          # ping matrix + port reachability
make verify             # the full acceptance test
```

Green on `make verify` means Phase 1 is functionally complete.

## Step 6 · Evidence

```bash
make evidence           # writes A1, A3, A4, A5, B1, B2, B3, D1
./scripts/capture.sh full   # then describe C1, C2, C3 by hand
make demo-fail          # choose A; writes D3
```

Then paste each file into its form field. [`evidence/README.md`](../evidence/README.md)
maps every field to the file that answers it, and lists the rules that cost marks.

---

## Quick reference

| Machine | Command | Leaves running |
|---|---|---|
| Mac 1 | `make dns` | dnsmasq (launchd) |
| Mac 2 | `make edge` | nginx |
| Mac 3 | `make backend-a` | foreground node |
| Mac 4 | `make backend-b` | foreground node |
| any | `make client-dns` `make client-trust` | — |
| client | `make verify` `make evidence` | — |

## Daily restart

Everything except the foreground backends survives a reboot.

```bash
# Mac 3 / Mac 4
make backend-a    # / backend-b

# anywhere
make restore      # fixes resolver + restarts this machine's service
make verify
```

## Shutting down cleanly

```bash
# Mac 1
sudo brew services stop dnsmasq
# Mac 2
sudo nginx -s stop
# Mac 3 / 4
Ctrl-C
# every machine
./infra/client/reset-dns.sh
```

## Common first-run problems

| Symptom | Cause | Fix |
|---|---|---|
| `dig` times out from a client | dnsmasq on `127.0.0.1` | `listen-address=0.0.0.0`, re-run `make dns` |
| Client lost internet after `client-dns` | dnsmasq not forwarding | check `server=1.1.1.1` and `no-resolv` |
| 502 on every request | Backend bound to loopback, or not running | `lsof -nP -iTCP:3001 -sTCP:LISTEN` on Mac 3 |
| `curl` cert error | CA not trusted here, or cert regenerated after distribution | `make client-trust` on every Mac |
| `X-Backend` always the same | One backend down | `./scripts/status.sh` on both |
| nginx will not bind | Port < 1024 without sudo | set `HTTPS_PORT=8443 HTTP_PORT=8080`, re-render |

Full table in [troubleshooting.md](troubleshooting.md).
