# Phase 2 Final Report — Team paradise

**Computer Networks (CSA223) · Review 2 · Extensions A–F**
Live run: **23 November 2026, 11:58–13:10 IST**, four MacBooks on the lab Wi-Fi (10.7.0.0/16).

| Member | Machine | Phase 2 role |
|---|---|---|
| Nipun | Mac 1 · 10.7.20.228 | Primary DNS, TTL (Ext B), main client for the captures, documentation |
| Anushka | Mac 2 · 10.7.3.123 | Primary edge, HA failover (Ext D), edge migration (Ext E) |
| Tajuddin Shaik | Mac 3 · 10.7.13.238 | Backend A, Ext A client, isolation (Ext C), tooling |
| Omkar Hadole | Mac 4 · 10.7.18.17 | Backend B, **backup DNS** (Ext A), **standby edge** (Ext E), troubleshooting (Ext F) |

Every number in this report comes from a file in [`evidence/phase2/`](../../evidence/phase2/README.md)
or a capture in [`evidence/captures/`](../../evidence/captures/). Each claim names its file.

---

## Contents

1. [Summary](#1-summary)
2. [What changed from Phase 1](#2-what-changed-from-phase-1)
3. [Resilience tests and results](#3-resilience-tests-and-results)
   - [3.1 Per-extension results](#31-per-extension-results)
   - [3.2 Real incidents found while running the demos](#32-real-incidents-found-while-running-the-demos)
4. [Troubleshooting findings (Extension F)](#4-troubleshooting-findings-extension-f)
5. [Learning summary, one paragraph per extension](#5-learning-summary-one-paragraph-per-extension)
6. [Remaining single point of failure](#6-remaining-single-point-of-failure)
7. [Rollback](#7-rollback)
8. [Evidence index](#8-evidence-index)

---

## 1. Summary

| Ext | Requirement (spec §7.1) | Result | Key number |
|---|---|---|---|
| **A** | Backup resolver; stop the primary; clients keep resolving | ✅ | Same query ID `0x90b0` re-sent to the backup **1.0 s** after the primary went silent; `curl` stayed **HTTP 200** |
| **B** | Visible TTL; old answer until expiry; manual flush | ✅ | TTL **30 s**; stale window **9 s** (sampled) / **11.4 s** (on the wire); after a flush **0–2 s** |
| **C** | Only the edge reaches :3001/:3002 | ✅ | From a client: **FILTERED** (5 SYNs, no reply). From Mac 2: **OPEN** |
| **D** | Kill Backend A under load; zero errors; A rejoins | ✅ | **145 requests, 0 non-200**, 37 consecutive B-only responses, A back at **50 s** |
| **E** | DNS cutover to a standby edge; observe the TTL | ✅ | `X-Edge` moved `nginx@10.7.3.123` → `nginx@10.7.18.17`, every request **200** |
| **F** | Diagnose injected faults layer by layer | ✅ | 3 injected faults, 3 correct verdicts; plus **3 real incidents** diagnosed the same way |
| — | Acceptance test `make p2-verify` | ✅ | **20/20** before the demos (12:11) and after every fault was undone (13:09) |

Running the demos for real exposed one design bug: a keep-alive timer race between
nginx and Node.js. Under failover it turned into **six HTTP 502s**. It was diagnosed
from the edge's error log, fixed with two timer values, and the demo was re-run clean
(§3.2, Incident 2). This is the most important thing we learned in Phase 2.

---

## 2. What changed from Phase 1

Phase 2 extends the Phase 1 system; nothing was rebuilt. Phase 2 renders the **same**
templates with overrides into `infra/phase2/build/`, and its scripts live in
`scripts/phase2/`.

| Area | Phase 1 | Phase 2 | Cloud equivalent |
|---|---|---|---|
| DNS servers | one, Mac 1 | two **independent** servers, Mac 1 + Mac 4 | Route 53's four name servers per zone |
| DNS TTL | 0 s, nothing cached | **30 s**, caching observable | record TTL lowered before a migration |
| Client resolvers | Mac 1 | Mac 1, **then** Mac 4 | VPC resolver with fallback |
| Backend ports | reachable by anyone on the LAN | only from the two edges (pf `block drop`) | Security Group allowing the ALB's SG only |
| Backend failure | passive `max_fails` | unchanged, plus a live health view (`p2-health-watch`) | ALB target health |
| Edge | Mac 2 only | Mac 2 + **standby on Mac 4**, chosen by DNS | second ALB + Route 53 failover |
| Edge ↔ backend keep-alive | nginx 60 s (default), Node 5 s (default) | nginx **4 s**, Node **65 s** | ALB idle timeout < target keep-alive |

**Phase 1 files changed in Phase 2: exactly two lines of intent.** One is
`keepalive_timeout 4s;` in `infra/mac2-edge/nginx/conf.d/site.conf.template`. The
other is `keepAliveTimeout`/`headersTimeout` in `services/backend/src/server.js`.
Both come from Incident 2. `make p2-test` asserts those values are present and
fails on any other change to Phase 1 code (55/55 checks pass).

**Tooling changed during the run:**
- `verify-phase2.sh` now writes **every check line** to its evidence file, not just
  the final tally.
- `ha-demo.sh` now requires a B-only window of **≥15 consecutive** responses and
  **at least one request nginx retried off Backend A**. The old check (`BBBBB`)
  passed once when A was never stopped, because round robin produces short B-runs
  by chance. We caught the false pass by counting retries (0) and deleted that run.

---

## 3. Resilience tests and results

### 3.1 Per-extension results

#### Extension A — Backup DNS resolver

**Setup.** Mac 4 runs a second dnsmasq with the same records, rendered from the
same template. It **does not forward to the primary**, so it doesn't share the
primary's fate. Every client's resolver list is `10.7.20.228, 10.7.18.17`
([A1](../../evidence/phase2/A-backup-dns/A1-resolvers-and-both-servers.txt)).

**Test.** Nipun stopped dnsmasq on Mac 1 (`make p2-dns-stop`) from **12:47:46 to
12:49:43**. This was observed from three places at once:

| Vantage point | What it showed | Evidence |
|---|---|---|
| Mac 3, a pure client | `dig @10.7.20.228` → *connection timed out*; normal `dig` → `SERVER: 10.7.18.17`, answer `10.7.3.123`; `curl` → **HTTP 200**; afterwards `SERVER: 10.7.20.228` again | [A-failover-demo.txt](../../evidence/phase2/A-backup-dns/A-failover-demo.txt) |
| Mac 1, sampled every 2 s | 0–72 s answered by the primary; **74–189 s** primary `DOWN`, every lookup still `10.7.3.123` from **10.7.18.17**; from 191 s back on the primary | [A2-failover-watch-mac1.txt](../../evidence/phase2/A-backup-dns/A2-failover-watch-mac1.txt) |
| Mac 4's own dnsmasq log | Mac 1's queries arrive every ~4 s until **12:49:41**, answered `config` (from its own data, not forwarded) | [A3-backup-dnsmasq-log.txt](../../evidence/phase2/A-backup-dns/A3-backup-dnsmasq-log.txt) |

**Packets** ([`p2-A-dns-failover.pcapng`](../../evidence/captures/p2-A-dns-failover.pcapng),
screenshots [W-A1](../../evidence/phase2/screenshots/W-A1-query-to-primary-unanswered.png),
[W-A2](../../evidence/phase2/screenshots/W-A2-same-id-retried-on-backup.png)):

| Frame | Time | Source → Destination | DNS ID | Meaning |
|---|---|---|---|---|
| 228 | 74.35 s | 10.7.20.228 → 10.7.20.228 | `0x6933` | query to the primary: **no response** |
| 230 | 75.37 s | 10.7.20.228 → 10.7.20.228 | `0x90b0` | next lookup to the primary: **no response** |
| 232 | 76.38 s | 10.7.20.228 → **10.7.18.17** | **`0x90b0`** | **the same query** re-sent to the backup, 1.0 s later |
| 233 | 76.61 s | 10.7.18.17 → 10.7.20.228 | `0x90b0` | `A 10.7.3.123`, TTL 30 |

Over the whole capture, the primary answered **117 of 174** queries (57 lost during
the outage), and the backup answered **28 of 28**.

**Result:** resolution never stopped. The cost was a **~1 s resolver timeout per
lookup** while the primary was down.

#### Extension B — DNS TTL and controlled record change

**Setup.** TTL raised from 0 to **30 s** on both servers
([B1](../../evidence/phase2/B-ttl/B1-ttl-in-answer.txt), screenshot
[W-B1](../../evidence/phase2/screenshots/W-B1-ttl-30-in-answer.png): the *TTL (s)*
column reads 30 on every answer from both servers).

**Test.** `make p2-ttl-watch` on Mac 1 printed, every ~2 s, three different
truths side by side:

- `dig`: asks the server directly and bypasses the cache.
- the OS cache: what `mDNSResponder` hands to applications.
- `curl`: where a real HTTPS request actually went.

Meanwhile the records were changed with `make p2-cutover` on Mac 1 and Mac 4.

| Change | dig flips | OS cache / curl flips | Stale window | Evidence |
|---|---|---|---|---|
| primary → standby (TTL expiry) | 12:55:03 | 12:55:12 | **9 s** (`STALE` ×4) | [ttl-watch-…125354](../../evidence/phase2/B-ttl/ttl-watch-20261123-125354.txt) |
| standby → primary (TTL expiry) | 12:56:57 | 12:57:06 | **9 s** (`STALE` ×4) | same file |
| primary → standby + **`make p2-flush`** | 12:59:02 | 12:59:02 | **0 s** | [ttl-watch-…125757](../../evidence/phase2/B-ttl/ttl-watch-20261123-125757.txt) |
| standby → primary + **`make p2-flush`** | 12:59:19 | 12:59:21 | **2 s** (one row: the gap between the dnsmasq restart and the flush) | same file |

**On the wire** ([`p2-BE-ttl-cutover.pcapng`](../../evidence/captures/p2-BE-ttl-cutover.pcapng),
screenshot [W-B2/E1](../../evidence/phase2/screenshots/W-B2-E1-dns-flips-then-clienthello-moves.png)):
frame **1002** (65.50 s) is the first DNS answer carrying `10.7.18.17`. Yet the
TLS ClientHellos in frames 1006, 1040, 1076, 1108 and 1148 still go to **10.7.3.123**.
The first ClientHello to **10.7.18.17** is frame **1195** (76.89 s), so the stale
period on the wire was **11.4 s**. While the cache is valid, the OS sends **no DNS
packet at all**. That's why the stale period is invisible in the DNS packets and
visible only in where TCP connects.

**Why 9–11 s and not 30 s.** The TTL counts down from when the OS **fetched** the
answer, not from when the record changed. The cached entry was already ~20 s old
at the moment of the change. Across many clients the stale period is spread
uniformly between 0 and 30 s.

#### Extension C — Service isolation (pf)

**Setup.** On Mac 3 and Mac 4, a pf anchor (`com.apple/250.ParadiseIsolation`)
passes :3001/:3002 only from the two edges' IPs and `block drop`s everything else.
The original pf state is kept for rollback (§7). The spec says *only Mac 2*. We also pass the standby edge (Mac 4), because after an Ext E cutover it must reach Backend A. Clients are blocked either way (rendered rules: [config bundle](../../evidence/phase2/config-bundle/README.md)).

| Vantage point | Backend A :3001 | Backend B :3002 | Through the edge by name | Evidence |
|---|---|---|---|---|
| Mac 1 (client) | **FILTERED** (timeout 3 s, `curl` 28) | **FILTERED** | HTTP 200 | [C-probe-from-10.7.20.228](../../evidence/phase2/C-isolation/C-probe-from-10.7.20.228.txt), [C1](../../evidence/phase2/C-isolation/C1-direct-vs-edge.txt) |
| Mac 2 (edge) | **OPEN** (0 s) | **OPEN** (0 s) | HTTP 200 | [C-probe-from-10.7.3.123](../../evidence/phase2/C-isolation/C-probe-from-10.7.3.123.txt) |

**Packets** ([`p2-C-isolation.pcapng`](../../evidence/captures/p2-C-isolation.pcapng),
screenshot [W-C1](../../evidence/phase2/screenshots/W-C1-syn-retransmissions-filtered.png)):
from Mac 1, 5 SYNs to `10.7.13.238:3001` at 0, 1, 2, 3 and 4 s (frames 1–5, all
from ephemeral port 62233), then 5 to `10.7.18.17:3002`. There is **no SYN-ACK and no RST**.
A closed port answers with RST at once (Phase 1's wrong-port demo). A filtered port
answers with nothing, so the client retransmits until it gives up. The two outcomes
are distinguishable, and that's the point of `block drop`.

#### Extension D — High-availability failover

**Setup.** Passive health checking: `max_fails=1 fail_timeout=10s` on both upstream
servers, and `proxy_next_upstream error timeout http_502 http_503 http_504` with
`proxy_next_upstream_tries 2`. A failed attempt is retried on the other backend
*inside the same client request*.

**Test.** `make p2-ha-demo` sent one request about every 0.7 s for 100 s from Mac 1.
Tajuddin pressed Ctrl-C on Backend A, then restarted it with `make backend-a`
([D-ha-demo-20261123-124350.txt](../../evidence/phase2/D-ha-failover/D-ha-demo-20261123-124350.txt)):

| Measure | Value |
|---|---|
| Requests | **145** |
| Non-200 responses | **0** |
| Served by A / B | 46 / 99 |
| Longest B-only run | **37 consecutive responses, 24 s → 49 s** (A down) |
| Requests nginx retried off dead A (`upstream=10.7.13.238:3001, 10.7.18.17:3002`) | **9**: at 24, 25, 28, 35, 42, 43, 46, 47 s (and one isolated retry at 80 s) |
| A back in rotation | **50 s** |
| Checks | **6/6** |

The 9 retries are how the client saw no errors. nginx tried A, got
`connect() failed (61: Connection refused)` (Mac 2 error log), and replayed the
request on B. Between retries, A was marked down for `fail_timeout`, so most
requests skipped it entirely. Each time the 10 s ban expired, one request probed A
again. That's why the retries come in roughly 10 s steps.

Steady-state round robin before the test:
[D1-steady-state-lb.txt](../../evidence/phase2/D-ha-failover/D1-steady-state-lb.txt).

This clean run came **after** fixing Incident 2. The same test before the fix gave
six 502s (§3.2).

#### Extension E — Controlled edge migration (DNS-based cutover)

**Setup.** Mac 4 runs a standby nginx with the same rendered config and the same
certificate (the SAN covers `app.paradise.test`; the CA is already trusted).
Pinned with `--resolve`, it completes a verified TLS 1.3 handshake, no `-k`, and
identifies itself as `X-Edge: nginx@10.7.18.17`
([E1](../../evidence/phase2/E-edge-cutover/E1-standby-edge.txt); both edges'
ClientHellos with the same SNI in
[W-E1](../../evidence/phase2/screenshots/W-E1-clienthello-both-edges.png)).

**Cutover.** This is the same run as Ext B. Changing the A records on both DNS
servers moved traffic from `nginx@10.7.3.123` to `nginx@10.7.18.17`. Clients that
had cached the old answer kept using the old edge for 9 s (sampled) or 11.4 s
(on the wire). **No request failed during either direction of the cutover.** Every
row in both watch files is HTTP 200, because the old edge stayed up until the
cache had drained.

**Operational lesson found during the run (Incident 4).** During the cut-back,
the backup was twice left pointing at the standby while the primary pointed at
Mac 2. A wrong target name (`TO=standby` instead of `TO=primary`) was typed on
Mac 4. `dig @10.7.20.228` returned `10.7.3.123` while `dig @10.7.18.17` returned
`10.7.18.17`. Clients saw nothing, because they ask the primary first. If Mac 1
had failed in that state, every client would have silently moved to the other edge.
We caught it by querying both servers directly. In production, zone transfers
(AXFR/IXFR) keep the secondaries consistent automatically.

### 3.2 Real incidents found while running the demos

These were **not** injected. They happened during the live run, were diagnosed
with the same top-down method as Ext F, and are kept as evidence in
[`F-troubleshooting/`](../../evidence/phase2/F-troubleshooting/).

**Incident 1: the primary edge vanished at the transport layer (12:27).**
[F-incident1](../../evidence/phase2/F-troubleshooting/F-incident1-edge-asleep-20261123-1227.txt)

| Layer | Check | Result |
|---|---|---|
| DNS | `dig app.paradise.test` | ✓ 10.7.3.123 |
| IP | `ping 10.7.3.123` | ✓ but **~800 ms RTT** (normal: 5–20 ms) |
| TCP | `nc -vz 10.7.3.123 443` and `:80` | ✗ **timed out**: no SYN-ACK, no RST |
| Isolation | same test against the standby edge 10.7.18.17:443 | ✓ HTTP 200 |

Verdict: transport layer, Mac 2 only, packets **dropped** (not refused). Cause:
**Mac 2 had gone to sleep.** A sleeping Mac's Wi-Fi can still answer ping (slowly,
in power-save) while nginx is frozen. Fix: `caffeinate -dims` on every Mac. Lesson:
ping proves layer 3 only, and *timeout vs refused* separates "something is
dropping packets" from "nothing is listening".

**Incident 2: six 502s during HA failover. A keep-alive race between nginx and Node.js (12:30).**
[F-incident2](../../evidence/phase2/F-troubleshooting/F-incident2-keepalive-race-20261123-1230.txt)

Symptom: when Backend A was stopped, requests #22–#36 included **six HTTP 502s**,
although Backend B was running throughout.

| Evidence | What it says |
|---|---|
| client: `upstream=10.7.18.17:3002, 10.7.13.238:3001, backend_pool` | nginx tried **B first and B failed**, then A (dead), then had nothing left |
| client: `upstream=backend_pool` | "no live upstreams": both peers marked down |
| Mac 2 error log, 12:30:54 | `upstream prematurely closed connection while reading response header from upstream … 10.7.18.17:3002`, at `urt=0.092` s, so **not** a timeout |
| Mac 2 error log, 12:21:39 and 12:32:10 | the same failure on B, and `Connection reset by peer` on A, **in steady state**, invisible to clients |

Root cause: two idle timers on the same TCP connection, in the wrong order.

```
nginx  upstream keepalive_timeout   60 s  (default)  — REUSES idle sockets
Node   server.keepAliveTimeout       5 s  (default)  — CLOSES idle sockets
```

After 5 idle seconds Node closed a pooled socket. In the same instant, one of
nginx's worker processes sent the next request down it. With both backends up,
`proxy_next_upstream` retried on the other backend and nobody noticed; the log
shows it happened at least twice before. With A dead, the retry went to A and
failed. `max_fails=1` then ejected B, **the last healthy peer**, for 10 s, and
every request in that window got 502.

Fix: order the timers so **the side that reuses a connection gives it up before
the side that closes it.**

```nginx
# site.conf.template, upstream backend_pool
keepalive_timeout 4s;
```
```js
// services/backend/src/server.js
server.keepAliveTimeout = 65_000;
server.headersTimeout   = 66_000;   // must exceed keepAliveTimeout
```

Re-test: the identical demo gave **145 requests, 0 non-200** (Ext D above).
Backend unit tests still pass (8/8), and `make p2-test` passes (55/55).

**Incident 3: the campus gateway answers TCP for hosts that don't exist (13:04).**
[F-incident3](../../evidence/phase2/F-troubleshooting/F-incident3-campus-middlebox.txt),
capture [`p2-F-middlebox.pcapng`](../../evidence/captures/p2-F-middlebox.pcapng)

While diagnosing the injected fault `dns-wrong-ip` (record → 10.255.255.1), layer 2
(ping) failed but layer 3 (**TCP :443) succeeded**, for an address with no host
behind it. Probing showed that :80 and :443 get a SYN-ACK from **any** off-LAN
address, :22 and ICMP get nothing, and TLS is then reset. The SYN-ACK arrives with
**IP TTL 63**, one less than our 64, so it comes from one hop away: the gateway
10.7.0.1. That makes it a transparent proxy or firewall, not the destination.
Lesson: a passing TCP check proves that *something* answered, not that the
intended server did. The diagnosis still named the correct layer (DNS: wrong
record), because it reports the **first** failing layer, and that's exactly why
the method works.

**Incident 4: inconsistent DNS servers after a cutover (12:57–13:00).** See Ext E
above.

---

## 4. Troubleshooting findings (Extension F)

### 4.1 Method

`make p2-diagnose` runs the layers in order and stops trusting the result at the
**first failure**:

| # | Layer | Command (what it runs) | What a failure means |
|---|---|---|---|
| 0 | Local config | `networksetup -getdnsservers Wi-Fi`, `/etc/hosts` | the client asks the wrong server, or never asks |
| 1 | DNS | `dig @primary`, `dig @backup`, `dig` (default), `dscacheutil` | no answer, or an answer that is neither edge |
| 2 | Network | `ping <ip>` | host unreachable (with caveats: Incidents 1 and 3) |
| 3 | Transport | TCP connect to `:443` | **refused** = nothing listening · **timeout** = something drops |
| 4 | TLS | `curl -v` **without `-k`** | certificate not trusted / wrong name / handshake failure |
| 5 | HTTP | `curl -i` | 502/504 = edge up, backends not |

### 4.2 Injected faults (practice for the faculty fault)

| Fault | Injected on | Layer 0 | 1 DNS | 2 ping | 3 TCP | 4 TLS | Verdict | Fix | Evidence |
|---|---|---|---|---|---|---|---|---|---|
| `dns-wrong-ip` | Mac 1 | ✓ | ✗ resolves to **10.255.255.1**, not an edge | ✗ | ✓* | ✗ curl 35 | **DNS (wrong record)** | `make p2-fault-undo` (= cutover back) | [F-diagnose-…130423](../../evidence/phase2/F-troubleshooting/F-diagnose-20261123-130423.txt) |
| `edge-down` | Mac 2 | ✓ | ✓ 10.7.3.123 | ✓ | ✗ **REFUSED (RST)** | — | **Transport (port closed)** | start nginx on Mac 2 | [F-diagnose-…130655](../../evidence/phase2/F-troubleshooting/F-diagnose-20261123-130655.txt), [screenshot](../../evidence/phase2/screenshots/F-2-edge-down-verdict.png) |
| `client-dns-wrong` | Mac 1 | ✗ resolvers = **8.8.8.8** | ✗ name does not resolve | — | — | — | **DNS (client resolver config)** | `make p2-client-dns` | [F-diagnose-…130829](../../evidence/phase2/F-troubleshooting/F-diagnose-20261123-130829.txt), [screenshot](../../evidence/phase2/screenshots/F-3-client-dns-wrong-verdict.png) |

\* The campus gateway, not a real host (Incident 3).

Two earlier diagnose runs from the start of the session are also kept.
[F-diagnose-…120030](../../evidence/phase2/F-troubleshooting/F-diagnose-20261123-120030.txt)
is a genuine **TLS (trust)** failure: every layer up to TCP passed, then `curl 60`,
because Mac 1 didn't yet trust the CA. It was fixed with `make client-trust`, never `-k`.
[F-diagnose-…120116](../../evidence/phase2/F-troubleshooting/F-diagnose-20261123-120116.txt)
shows the same Mac healthy 46 s later.

### 4.3 Faculty-injected fault (Review 2)

To be filled in at the evaluation: **fault:** ___ · **first failing layer:** ___ ·
**command that showed it:** ___ · **fix:** ___ · **time to diagnose:** ___

### 4.4 What we take into the evaluation

- Always run the **standby edge** test in step 3. It isolates "this edge" from
  "the network" in one command (Incident 1).
- Read **timeout vs refused** before anything else at the transport layer.
- When DNS is in question, query **both** servers directly. The default `dig`
  only shows the primary (Incident 4).
- Look in the edge's **site error log**, `/opt/homebrew/var/log/nginx/paradise-error.log`,
  not the global `error.log`. We lost time on that.

---

## 5. Learning summary, one paragraph per extension

**A — Backup DNS.** A resolver list is a sequential fallback, not load balancing.
The client sends the query to the first server, waits about a second, and re-sends
the *same* query (same transaction ID, `0x90b0` in our capture) to the next one. A
primary outage therefore costs every lookup roughly one second but never an
answer. The backup must hold the records itself rather than forward to the
primary, or it fails with the primary. The demo also makes a distinction concrete.
A **DNS failure** stops resolution while `ping` to the edge's IP still works. An
**application failure** leaves resolution, TCP and TLS working, and only the HTTP
status (502) shows it. Different first-failing layer, different fix.

**B — TTL.** There are three different answers to "where does this name point"
at any moment. The server's (what `dig` shows), the OS cache's (what applications
use), and where TCP actually connects. They differ for up to one TTL after a
change. We measured 9 s sampled and 11.4 s on the wire with a 30 s TTL, because
the countdown starts when the answer was cached, not when the record changed. A
manual flush removes the gap at once (0–2 s), but only on the machine that
flushes. In production you can't flush other people's caches, so a migration
lowers the TTL well **before** the cutover. Once the old TTL has expired
everywhere, the change takes effect quickly, and you raise the TTL again afterwards.

**C — Service isolation.** A firewall can refuse in two observable ways. A RST
(CLOSED, immediate) or silence (FILTERED, SYN retransmissions until timeout). We
chose `block drop`, so isolation looks different from Phase 1's closed-port demo,
and a scanner learns nothing. The rule matches by source IP. The same backend port
is OPEN from Mac 2 and FILTERED from Mac 1, which is the "inbound only from the
load balancer's security group" rule used in AWS. Putting the rules in a pf
**anchor** and enabling pf with a reference token made the rollback exact: flush
one anchor, release one token, no system file touched.

**D — HA failover.** Open-source nginx detects backend failure **passively**,
from real traffic. One failed attempt marks the peer down for `fail_timeout`, and
`proxy_next_upstream` replays that same request on the survivor, so the client
sees 200. Our capture of that shows as `upstream=A, B` on 9 requests out of 145,
with 0 errors. The real lesson came from the run that failed. Redundancy hides
latent faults: the keep-alive race had been happening in steady state, invisibly,
until one backend was gone and the retry had nowhere to land. `max_fails=1` makes
failover fast but makes the *last* healthy peer easy to eject, and timer ordering
between proxy and backend (reuser < closer) is a correctness requirement, not a
tuning detail.

**E — Edge migration.** DNS-based cutover is bounded by the TTL, and it's
**gradual**: each client moves when its own cache entry expires. For a whole
population that means up to one full TTL. The old edge must keep serving until the
longest TTL has drained. We kept Mac 2 up throughout, which is why the cutover
had zero errors. Both DNS servers must change together (Incident 4). The standby
needed no new trust because it reuses the certificate whose SAN covers the name.
That's the edge-migration form of "clients connect by name, never by IP".

**F — Troubleshooting.** Diagnose top-down, and the **first** failing layer is the
verdict. Everything after it is either explained by it or untrustworthy. Our
three real incidents taught where each layer's check can mislead. Ping can succeed
on a sleeping host (Incident 1). TCP can "succeed" against a middlebox standing in
for a host that doesn't exist (Incident 3). One server's view of DNS isn't the
whole truth (Incident 4). In each case the method still worked, because it pairs
each check with a contrast: timeout vs refused, primary vs standby edge, primary
vs backup DNS.

---

## 6. Remaining single point of failure

**Edge selection.** The standby removes Mac 2 as a permanent SPOF, but failing
over to it is a **manual** DNS change, bounded by the TTL. To remove it:

1. **A floating virtual IP** (VRRP/keepalived, CARP). Both edges share one IP, and
   the standby claims it within about a second, with no DNS change.
2. **Health-checked DNS failover** (Route 53 failover records). DNS stops returning
   a dead edge automatically; the TTL still bounds the switch.
3. **Anycast or a global load balancer** in front of both edges.

**Shared fate on Mac 4.** Backend B, the backup DNS and the standby edge all run on
Mac 4. No *single* machine failure stops the service (Mac 1 → Mac 2 → Mac 3 still
works), but Mac 1 and Mac 4 failing together would leave no DNS at all. Production
spreads these across failure domains. Details:
[architecture.md](architecture.md#shared-fate-on-mac-4).

---

## 7. Rollback

Phase 2 keeps a rollback copy of everything it changes. After the evaluation,
run on each machine:

```bash
make p2-rollback            # everything Phase 2 changed on THIS machine
make p2-rollback WHAT=isolation   # Mac 3 / Mac 4: flush the pf anchor, release the token
make p2-status              # confirm: no anchor, no standby nginx, resolvers restored
```

`p2-rollback` restores `dnsmasq.conf.pre-phase2`, the client resolver list saved
in `infra/phase2/build/state/client-dns-before-phase2.txt`, and stops the standby
nginx. The pf rules were applied only to the anchor, so nothing in `/etc/pf.conf`
needs restoring.

---

## 8. Evidence index

| Ext | Terminal output | Packets | Screenshots |
|---|---|---|---|
| A | [A-failover-demo](../../evidence/phase2/A-backup-dns/A-failover-demo.txt) · [A1](../../evidence/phase2/A-backup-dns/A1-resolvers-and-both-servers.txt) · [A2](../../evidence/phase2/A-backup-dns/A2-failover-watch-mac1.txt) · [A3](../../evidence/phase2/A-backup-dns/A3-backup-dnsmasq-log.txt) | `p2-A-dns-failover.pcapng` | W-A1, W-A2 |
| B | [B1](../../evidence/phase2/B-ttl/B1-ttl-in-answer.txt) · [watch 1](../../evidence/phase2/B-ttl/ttl-watch-20261123-125354.txt) · [watch 2 (flush)](../../evidence/phase2/B-ttl/ttl-watch-20261123-125757.txt) | `p2-B-ttl.pcapng`, `p2-BE-ttl-cutover.pcapng` | W-B1, W-B2-E1 |
| C | [from Mac 1](../../evidence/phase2/C-isolation/C-probe-from-10.7.20.228.txt) · [from Mac 2](../../evidence/phase2/C-isolation/C-probe-from-10.7.3.123.txt) · [C1](../../evidence/phase2/C-isolation/C1-direct-vs-edge.txt) | `p2-C-isolation.pcapng` | W-C1 |
| D | [HA demo](../../evidence/phase2/D-ha-failover/D-ha-demo-20261123-124350.txt) · [D1](../../evidence/phase2/D-ha-failover/D1-steady-state-lb.txt) | — | — |
| E | [E1](../../evidence/phase2/E-edge-cutover/E1-standby-edge.txt) · the B watch files | `p2-E-two-edges.pcapng`, `p2-BE-ttl-cutover.pcapng` | W-E1, W-B2-E1 |
| F | 5 × `F-diagnose-*` · 3 × `F-incident*` | `p2-F-middlebox.pcapng` | F-2, F-3 |
| config | [config bundle](../../evidence/phase2/config-bundle/README.md): rendered dnsmasq (both), nginx (both edges), pf (both backends) | | |
| all | [verify 12:11](../../evidence/phase2/verify-phase2-20261123-121147.txt) · [verify 13:09](../../evidence/phase2/verify-phase2-20261123-130949.txt) | | |

Captures are in [`evidence/captures/`](../../evidence/captures/); screenshots are in
[`evidence/phase2/screenshots/`](../../evidence/phase2/screenshots/). The frame
numbers quoted above match the committed captures.
