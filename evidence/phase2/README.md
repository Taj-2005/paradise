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

## Collected: live run, 23 Nov 2026

Every file below is real output. Results and the story behind each are in
[docs/phase2/report.md](../../docs/phase2/report.md).

| Ext | Files | Captured by | Headline |
|---|---|---|---|
| A | `A-failover-demo.txt` (Mac 3) · `A1-…` · `A2-failover-watch-mac1.txt` · `A3-backup-dnsmasq-log.txt` (Mac 4, filtered to `paradise.test`) | Tajuddin, Nipun, Omkar | primary down 12:47:46–12:49:43, every lookup answered by 10.7.18.17 |
| B | `B1-…` · `ttl-watch-20261123-125354.txt` (TTL expiry, both directions) · `ttl-watch-20261123-125757.txt` (with flush) | Nipun | stale 9 s without a flush, 0–2 s with one |
| C | `C-probe-from-10.7.20.228.txt` (FILTERED) · `C-probe-from-10.7.3.123.txt` (OPEN) · `C1-…` | Nipun, Anushka | same pf rules, two vantage points |
| D | `D-ha-demo-20261123-124350.txt` · `D1-…` | Nipun (client), Tajuddin (stopped A) | 145 requests, 0 non-200, 9 retries off A |
| E | `E1-standby-edge.txt` + the B watch files | Nipun, Omkar | `X-Edge` moved to `nginx@10.7.18.17`, no failed request |
| F | `F-diagnose-*` (5 runs) · `F-incident1/2/3-*` (real incidents, not injected) | Nipun, Anushka | DNS / Transport / DNS-config verdicts, all correct |
| all | `verify-phase2-20261123-121147.txt` (before) · `…-130949.txt` (after) | Nipun | 20/20 both times |

**Captures** (`evidence/captures/`, committed; frame numbers match the
screenshots): `p2-A-dns-failover`, `p2-B-ttl`, `p2-BE-ttl-cutover`,
`p2-C-isolation`, `p2-E-two-edges`, `p2-F-middlebox` (all `.pcapng`).

**Screenshots** (`screenshots/`):

| File | Shows |
|---|---|
| `W-A1-query-to-primary-unanswered.png` | frame 230, ID `0x90b0` to the primary, no response |
| `W-A2-same-id-retried-on-backup.png` | frames 232–233, the same ID re-sent to 10.7.18.17 and answered |
| `W-B1-ttl-30-in-answer.png` | TTL column = 30 on answers from both servers |
| `W-B2-E1-dns-flips-then-clienthello-moves.png` | DNS answer flips at frame 1002; ClientHellos keep going to the old edge until frame 1195 |
| `W-C1-syn-retransmissions-filtered.png` | 5 SYNs per backend port, no SYN-ACK, no RST |
| `W-E1-clienthello-both-edges.png` | same SNI, TLS 1.3 to both edges |
| `F-2-edge-down-verdict.png` · `F-3-client-dns-wrong-verdict.png` | diagnose verdicts for two injected faults |

Not yet in the folder: the teammates' own terminal screenshots (Ext A on Mac 3,
the Mac 4 dnsmasq log, `p2-health-watch` on Mac 2). Add them as
`<Ext>-<n>-<what>.png` when they're shared.

## What to capture for each extension

Two kinds of proof: **terminal output** (`.txt`, written by the scripts, no
colour codes) and **screenshots** (terminal and Wireshark). Save screenshots in
[`screenshots/`](screenshots/) as `<Ext>-<n>-<what>.png`, for example
`A-1-dig-failover.png`. Every Wireshark screenshot must show the **filter bar,
the packet list and the packet-details pane** so the reader can see what was
filtered.

| Ext | `.txt` (auto) | Terminal screenshots | Wireshark screenshots |
|---|---|---|---|
| A | `A-backup-dns/*` | `dig` showing `communications error to <Mac 1>` then `SERVER: <Mac 4>`; `curl` still 200 | W-A1, W-A2 |
| B | `B-ttl/*` | TTL watch at the `STALE` line; again at `CUT OVER after Ns`; `p2-flush` flipping it at once | W-B1, W-B2 |
| C | `C-isolation/*` | `p2-isolation-test` on Mac 2 (OPEN) and Mac 1 (FILTERED); `curl` direct to :3001 timing out | W-C1, W-C2 |
| D | `D-ha-failover/*` | `p2-health-watch` (Mac 2) and `p2-ha-demo` (client) **side by side** during the outage | W-D1 (optional) |
| E | `E-edge-cutover/*` | `X-Edge` changing from `nginx@<Mac 2>` to `nginx@<Mac 4>` | W-E1 |
| F | `F-troubleshooting/*` | `p2-diagnose` for 2 or 3 injected faults, each ending in its layer verdict | none needed |

## Wireshark: how to simulate and capture

Capture on the **client** unless the table says otherwise. Run `tcpdump` in
terminal 1, trigger the event in terminal 2, stop with Ctrl-C, then open the
file. Captures are gitignored; keep them for the demo.

Shortcut: `make p2-capture MODE=dns|isolation|ha|cutover` runs the tcpdump with
the right capture filter and prints the trigger and display filter. Manual form:

```bash
# terminal 1 (interface is en0 unless your .env says otherwise)
sudo tcpdump -i en0 -s0 -w evidence/captures/p2-A-dns-failover.pcapng 'udp port 53'
# terminal 2: trigger the event (commands below), then Ctrl-C terminal 1
open -a Wireshark evidence/captures/p2-A-dns-failover.pcapng
```

### Ext A: DNS failover (client)

- **Capture filter:** `udp port 53`
- **Simulate:** `make p2-dns-stop` on Mac 1, then on the client
  `sudo dscacheutil -flushcache; dig app.paradise.test`
- **Display filter:** `dns.qry.name == "app.paradise.test"`
- **W-A1:** query to Mac 1 repeated with **no response** (Wireshark marks
  "no response seen"). **W-A2:** the next query to Mac 4 and its response with
  the A record. Name both IPs and the port in the write-up.

### Ext B and E: TTL and cutover (client)

- **Capture filter:** `udp port 53`
- **Simulate:** `make p2-ttl-watch` on the client while Mac 1 and Mac 4 run
  `make p2-cutover TO=standby`; later `make p2-flush`.
- **Display filter:** `dns.flags.response == 1 && dns.qry.name == "app.paradise.test"`
- **One-time setup:** right-click **Time to live** in the DNS answer, choose
  *Apply as Column*; then *View > Time Display Format > Seconds Since Previous
  Displayed Packet*.
- **W-B1:** the TTL column reads **30** (Phase 1 read 0). **W-B2:** the A record
  changes from the edge to the standby, and the time column shows the gap between
  lookups, which is the cache holding the old answer. Within the TTL the OS
  answers from cache and **no packet appears at all**: say so.
- **W-E1 (TLS to the new edge):** display filter
  `tls.handshake.type == 1 && ip.dst == <Mac 4>`. A ClientHello to the standby
  after the cutover proves traffic moved. For the SNI, expand
  *Extension: server_name*.

### Ext C: isolation (capture on Mac 3, and on the client)

- **Capture filter:** `tcp port 3001`
- **Simulate:** from a client run `curl --connect-timeout 5 http://<Mac 3>:3001/healthz`,
  then from Mac 2 run `curl http://<Mac 3>:3001/healthz`.
- **Display filter:** `tcp.port == 3001`
- **W-C1 (from the client, blocked):** SYN, then SYN retransmissions
  (`tcp.analysis.retransmission`), **no SYN-ACK and no RST**. That is FILTERED, not
  CLOSED. **W-C2 (from Mac 2, allowed):** SYN, SYN-ACK, ACK, then HTTP.
- tcpdump sees the SYN arrive on Mac 3 even though pf drops it afterwards, so a
  capture on Mac 3 shows the SYN with no reply. A capture on the client shows
  the same silence from the other side.

### Ext D: HA failover (optional, capture on Mac 2)

- **Capture filter:** `tcp port 3001 or tcp port 3002`
- **Simulate:** `make p2-ha-demo` on the client, Ctrl-C Backend A at about 10 s.
- **Display filter:** `tcp.flags.reset == 1 && tcp.srcport == 3001`
- **W-D1:** RST from Backend A after it stops, then every request going to B.
  This shows nginx skipping a dead upstream, which is different from the
  silent drop in Ext C.

### Filters to keep handy

| Goal | Display filter |
|---|---|
| All lab DNS | `dns && dns.qry.name == "app.paradise.test"` |
| Unanswered queries | `dns.flags.response == 0` then look for "no response seen" |
| TTL on answers | `dns.resp.ttl` (add as a column) |
| Only A records | `dns.qry.type == 1` |
| Handshake starts | `tcp.flags.syn == 1 && tcp.flags.ack == 0` |
| Retransmitted SYNs | `tcp.analysis.retransmission && tcp.flags.syn == 1` |
| Resets | `tcp.flags.reset == 1` |
| ClientHello + SNI | `tls.handshake.type == 1` |
| One edge only | `ip.addr == <Mac 2 or Mac 4>` |

Rules from Phase 1 still apply: never use `-k`, always use names rather than
IPs in URLs, and paste real output only. Wireshark write-ups need specifics
(IPs, ports, packet types, what each proves), as in `evidence/C-wireshark/`.
