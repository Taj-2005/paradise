# Wireshark screenshots

Naming: `C<n>-<what-it-shows>` — form field first, so the right image is obvious
when filling in Section C.

## Primary evidence — one per form field

All three are from clean, scoped captures (47–66 packets) taken against the
current edge at `10.7.8.155`, so they agree with each other and with the
terminal evidence in `../../`.

| File | Filter | What is on screen |
|---|---|---|
| `C1-dns-query-and-response.jpeg` | `dns` | Both packets. Query `0xba40 A app.paradise.test` from `10.7.26.203` to `10.7.27.161`; response from `10.7.27.161` carrying `app.paradise.test A 10.7.8.155`. Detail pane expanded: UDP src port **53** → 56279, `Queries: app.paradise.test type A class IN`, `Answers`, round trip 12 ms. |
| `C2-tcp-syn-and-synack.jpeg` | `tcp.flags.syn==1` | `10.7.26.203:53215 → 10.7.8.155:443 [SYN] Seq=0 Len=0`, then `443 → 53215 [SYN, ACK] Seq=0 Ack=1`. Detail pane expanded on the SYN: Source Port 53215, Destination Port 443, `Flags: 0x002 (SYN)`, `TCP Segment Len: 0`. |
| `C3-tls-clienthello-sni.jpeg` | `tls` | `Client Hello (SNI=app.paradise.test)` from `10.7.26.203` to `10.7.8.155`, then `Server Hello, Change Cipher Spec, Application Data`, then Application Data only. Hex pane shows `app.paradise.test` and `http/1.1` in the clear inside the Client Hello. |

Between them these answer C1, C2 and C3 completely: named source and destination
addresses, the ports, the packet types, and — for C3 — the point at which the
conversation stops being readable.

## Earlier captures, kept for reference

| File | Note |
|---|---|
| `C1-dns-response-detail-earlier-capture.png` | Same DNS fields expanded, from a capture taken while the edge was `10.7.31.205`. Superseded by the JPEG above, which matches the current address. |
| `C2-tcp-broad-capture-earlier.png` | A wider capture of everything on port 443, scoped to the client rather than the edge, so it includes external connections alongside ours. |

## Why the newer three work better

They were scoped **at capture time** rather than filtered afterwards, so the
file holds only this project's traffic — 2 displayed of 66 packets for C1, 2 of
47 for C2, 12 of 66 for C3. Nothing unrelated is on screen, and the two or three
rows that matter are the only rows there.

To repeat it: **Capture → Options → Capture Filter for selected interfaces**

```
host 10.7.8.155 or host 10.7.27.161 or port 53
```
