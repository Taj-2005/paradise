# IP and service inventory

> Fill the real values in before the review. `./scripts/status.sh` prints the
> live state of whichever machine you run it on, and `make evidence` writes the
> full table into `evidence/A-lan-dns/A1-ips.txt` — this file is the
> human-readable copy for the architecture document.

## Machines

| # | Role | Hostname | Private IPv4 | Netmask | Gateway | Interface | MAC |
|---|---|---|---|---|---|---|---|
| Mac 1 | Private DNS + client · **Phase 2:** TTL 30 | Nipuns-MacBook-Pro | 10.7.20.228 | 255.255.224.0 (/19) | 10.7.0.1 | en0 | 82:02:70:03:85:1f |
| Mac 2 | Edge (nginx) | Anushkas-MacBook-Pro | 10.7.3.123 | 255.255.224.0 (/19) | 10.7.0.1 | en0 | ce:c0:5f:6c:62:e4 |
| Mac 3 | Backend A + client | Tajs-Macbook-Pro | 10.7.13.238 | 255.255.224.0 (/19) | 10.7.0.1 | en0 | 52:44:1c:a3:70:f3 |
| Mac 4 | Backend B + client · **Phase 2:** backup DNS, standby edge | Omkars-MacBook-Pro | 10.7.18.17 | 255.255.224.0 (/19) | 10.7.0.1 | en0 | 02:26:ba:a9:2f:1a |

Measured **23 Nov 2026** (Phase 2 live run). Mac 1's row comes from `ipconfig`/`ifconfig`
on Mac 1. The other MAC addresses come from Mac 1's ARP table (`arp -an`); they
are on the same Wi-Fi segment, so mask and gateway are the same DHCP lease values.
macOS uses a **private (randomised) Wi-Fi MAC per network**, which is why some
addresses have the locally-administered bit set (`x2:`, `xe:`). DHCP also gave
different addresses on the Phase 1 day (e.g. Mac 3 was 10.7.26.203); the Phase 1
evidence files record those, dated. **Re-check this table on demo day**: if any
address changed, update `.env`, run `make render`, and re-run `make dns`/`make edge`.

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
| `app.paradise.test` | A | 10.7.3.123 (Mac 2) | 0 (Phase 1) → **30 (Phase 2)** |
| `api.paradise.test` | A | 10.7.3.123 (Mac 2) | 0 (Phase 1) → **30 (Phase 2)** |

Both point at the **edge**, never at a backend. Served identically by the primary
(Mac 1) and the backup (Mac 4). During the Ext E cutover both briefly point at the
standby edge, 10.7.18.17.

## Phase 2 additions

| Service | Machine | Port | Rule / note |
|---|---|---|---|
| backup dnsmasq | Mac 4 | 53 UDP/TCP | same records, does **not** forward to Mac 1 |
| standby nginx | Mac 4 | 80, 443 | same config + certificate as Mac 2 |
| pf anchor `com.apple/250.ParadiseIsolation` | Mac 3, Mac 4 | 3001 / 3002 | pass from 10.7.3.123 and 10.7.18.17 only, `block drop` the rest |

## Ping matrix

Run `make preflight` on each machine and record the result.

| from → to | Mac 1 | Mac 2 | Mac 3 | Mac 4 |
|---|---|---|---|---|
| **Mac 1** | — | 0% loss | 0% loss | 0% loss |
| **Mac 2** | | — | | |
| **Mac 3** | | | — | |
| **Mac 4** | | | | — |

Mac 1's row: `ping -c3` to each Mac, 23 Nov 2026 12:27 IST, all 3/3 received.
Rows 2–4 are filled from each Mac's own `make preflight` (the Phase 1 record of a
full row is `evidence/A-lan-dns/A5-ping-matrix.txt`, taken from Mac 3).

Form field A5 accepts the summarised form:

```
Mac1 → Mac2: ping 10.0.0.11 — 4 packets, 0% loss
Mac1 → Mac3: ping 10.0.0.12 — 4 packets, 0% loss
...
```
