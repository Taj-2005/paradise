# IP and service inventory

> Fill the real values in before the review. `./scripts/status.sh` prints the
> live state of whichever machine you run it on, and `make evidence` writes the
> full table into `evidence/A-lan-dns/A1-ips.txt` — this file is the
> human-readable copy for the architecture document.

## Machines

| # | Role | Hostname | Private IPv4 | Netmask | Gateway | Interface | MAC |
|---|---|---|---|---|---|---|---|
| Mac 1 | Private DNS + client | | | | | en0 | |
| Mac 2 | Edge (nginx) | | | | | en0 | |
| Mac 3 | Backend A | | | | | en0 | |
| Mac 4 | Backend B + client | | | | | en0 | |

Collect each row on the machine itself:

```bash
hostname -s
ipconfig getifaddr en0
ipconfig getoption en0 subnet_mask
route -n get default | awk '/gateway:/{print $2}'
ifconfig en0 | awk '/ether/{print $2}'
```

## Services and ports

| Service | Machine | Bind address | Port | Protocol | Notes |
|---|---|---|---|---|---|
| dnsmasq | Mac 1 | `0.0.0.0` | 53 | UDP + TCP | Authoritative for `*.paradise.test` |
| nginx (redirect) | Mac 2 | `0.0.0.0` | 80 / 8080 | TCP | 301 → HTTPS |
| nginx (TLS) | Mac 2 | `0.0.0.0` | 443 / 8443 | TCP | TLS termination + load balancing |
| Backend A | Mac 3 | `0.0.0.0` | 3001 | TCP | `X-Backend: A` |
| Backend B | Mac 4 | `0.0.0.0` | 3002 | TCP | `X-Backend: B` |

Every service binds `0.0.0.0`. Anything on `127.0.0.1` is unreachable from the
other machines — the most common failure in this project.

## DNS records

| Name | Type | Value | TTL |
|---|---|---|---|
| `app.paradise.test` | A | Mac 2's IP | 0 (Phase 1) |
| `api.paradise.test` | A | Mac 2's IP | 0 (Phase 1) |

Both point at the **edge**, never at a backend.

## Ping matrix

Run `make preflight` on each machine and record the result.

| from → to | Mac 1 | Mac 2 | Mac 3 | Mac 4 |
|---|---|---|---|---|
| **Mac 1** | — | | | |
| **Mac 2** | | — | | |
| **Mac 3** | | | — | |
| **Mac 4** | | | | — |

Form field A5 accepts the summarised form:

```
Mac1 → Mac2: ping 10.0.0.11 — 4 packets, 0% loss
Mac1 → Mac3: ping 10.0.0.12 — 4 packets, 0% loss
...
```
