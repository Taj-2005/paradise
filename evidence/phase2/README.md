# evidence/phase2 — Phase 2 evidence

The scripts write every file here with a header (machine, role, date,
generating script) and **no colour codes**, so files can be pasted straight
into the report. Phase 1 evidence in `evidence/A-…`–`D-…` is untouched.

| Folder | Extension | Written by | Run on |
|---|---|---|---|
| `A-backup-dns/` | A backup DNS | `make p2-demo-dns-failover`, `make p2-evidence` | client (Mac 4) |
| `B-ttl/` | B TTL + E cutover | `make p2-ttl-watch`, `make p2-evidence` | client |
| `C-isolation/` | C pf isolation | `make p2-isolation-test` (one file per vantage point), `make p2-evidence` | Mac 2 **and** Mac 1 |
| `D-ha-failover/` | D HA failover | `make p2-ha-demo`, `make p2-health-watch`, `make p2-evidence` | client + Mac 2 |
| `E-edge-cutover/` | E standby edge | `make p2-evidence` (+ the B-ttl watch during cutover) | client |
| `F-troubleshooting/` | F diagnosis | `make p2-diagnose` | client |
| `verify-phase2-*.txt` | all | `make p2-verify` | client |

## Screenshots worth taking

- **Ext A:** `dig` output showing `communications error to <Mac 1>` followed by
  `SERVER: <Mac 3>`.
- **Ext B/E:** the TTL watch at the moment the SERVER column has flipped but
  OS-CACHE has not (the `STALE` note), and again at `CUT OVER after Ns`.
- **Ext C:** Wireshark on Mac 1, filtered with `tcp.port==3001`, showing SYN
  then retransmissions and no SYN-ACK or RST.
- **Ext D:** `p2-health-watch` (Mac 2) and `p2-ha-demo` (client) side by side
  during the outage.

Rules from Phase 1 still apply: never use `-k`, always use names rather than
IPs in URLs, and paste real output only.
