# Phase 2 Final Report — Team paradise

> Skeleton for the Phase 2 deliverable (spec §9: *what changed from Phase 1 ·
> resilience tests and results · troubleshooting findings · learning summary,
> one paragraph per extension*). Replace every `<<< … >>>` with real results
> from `evidence/phase2/`.

## 1. What changed from Phase 1

See [architecture.md](architecture.md) for the full table. In short: a second
independent DNS resolver (Mac 4), TTL 0 → 30 s, client resolver lists with two
entries, pf isolation of the backend ports, a live health view on the edge, and
a standby nginx edge on Mac 4 reached by DNS cutover. Every Phase 1 template is
reused unchanged. Phase 2 renders them with overrides.

## 2. Resilience tests and results

| # | Test | Command | Expected | Observed | Evidence |
|---|---|---|---|---|---|
| A | Primary DNS stopped | `make p2-demo-dns-failover` | `dig` falls through to Mac 4, curl 200 | <<< >>> | `A-backup-dns/A-failover-demo.txt` |
| B | Record change, TTL 30 | `make p2-ttl-watch` + `p2-cutover` | dig flips now, OS cache after ≤30 s | <<< seconds stale >>> | `B-ttl/ttl-watch-*.txt` |
| B | Manual flush | `make p2-flush` | immediate flip | <<< >>> | same |
| C | Client → :3001 directly | `make p2-isolation-test` on Mac 1 | timeout (FILTERED) | <<< >>> | `C-isolation/C-probe-from-*.txt` |
| C | Edge → :3001 | `make p2-isolation-test` on Mac 2 | 200 (OPEN) | <<< >>> | same |
| D | Backend A killed under load | `make p2-ha-demo` | 0 non-200, B-only window | <<< n requests, 0 errors >>> | `D-ha-failover/D-ha-demo-*.txt` |
| D | Backend A restarted | same | A rejoins within `fail_timeout` | <<< seconds >>> | same |
| E | DNS cutover to standby | `p2-cutover TO=standby` | X-Edge changes after TTL | <<< >>> | `B-ttl/ttl-watch-*.txt`, `E-edge-cutover/E1-standby-edge.txt` |
| — | Acceptance | `make p2-verify` | all checks pass | <<< N/N >>> | `verify-phase2-*.txt` |

## 3. Troubleshooting findings (Extension F)

**Fault injected by faculty:** <<< what was broken >>>

**Diagnosis, layer by layer:**

| Layer | Command | Result | Conclusion |
|---|---|---|---|
| 0 local | `networksetup -getdnsservers Wi-Fi`, `/etc/hosts` | <<< >>> | <<< >>> |
| 1 DNS | `dig app.paradise.test` | <<< >>> | <<< >>> |
| 2 network | `ping <ip>` | <<< >>> | <<< >>> |
| 3 TCP | `nc -vz <ip> 443` | <<< >>> | <<< >>> |
| 4 TLS | `curl -v` | <<< >>> | <<< >>> |
| 5 HTTP | `curl -i` | <<< >>> | <<< >>> |

**Fix applied:** <<< >>>   **Time to diagnose:** <<< >>>

Practice runs (`make p2-fault`) and what we learned: <<< >>>

## 4. Learning summary (one paragraph per extension)

**A — Backup DNS.** <<< e.g. why the backup must not forward to the primary; how
macOS falls through resolvers; how a DNS failure differs from an application failure >>>

**B — TTL.** <<< the gap between what the server says (dig) and what the OS
uses (cache); lowering the TTL *before* a migration; what flushing does >>>

**C — Service isolation.** <<< filtered vs closed; why pf anchors; least
privilege and the Security Group analogy >>>

**D — HA failover.** <<< passive vs active health checks; `proxy_next_upstream`
hiding the failure from the client; why the edge is still a SPOF >>>

**E — Edge migration.** <<< DNS-based cutover is bounded by the TTL; old
clients keep hitting the old edge, so it must stay up until the TTL drains >>>

**F — Troubleshooting.** <<< top-down method; first failing layer = verdict >>>
