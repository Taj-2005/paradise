# Wireshark screenshots

Naming: `C<n>-<what-it-shows>.png` — the form field first, so the right image is
obvious when filling in Section C. All taken from
[`../../captures/full-1.pcapng`](../../captures/full-1.pcapng).

| File | Filter | Shows |
|---|---|---|
| `C1-dns-query-response-list.png` | `dns && ip.addr==10.7.27.161` | Packet list with the query and its answer: `Standard query 0x9969 A app.paradise.test`, then `Standard query response 0x9969 A app.paradise.test A 10.7.31.205` |
| `C1-dns-response-answer-section.png` | same, response expanded | Packet detail: IPv4 `10.7.27.161` → `10.7.26.203`, UDP port 53 → 56279, `Answers: app.paradise.test type A addr 10.7.31.205`, Transaction ID `0xba40` |
| `C2-tcp-syn-client-scoped.png` | `ip.addr==10.7.26.203 && tcp.port==443 && tcp.len==0` | Every zero-length TCP packet on port 443 involving this client — SYN, SYN-ACK and bare ACK across all of its connections |
| `C3-tls-client-scoped.png` | `ip.addr==10.7.26.203 && tls` | Every TLS record involving this client, including Client Hello, Server Hello and Change Cipher Spec |

C1 is covered twice over — the list view shows the query/response pair, the
detail view proves source, destination, port and the answer record.

## Note on the C2 and C3 filters

Both are scoped to `10.7.26.203`, which is the capturing machine. That matches
every connection the laptop has open, so the visible rows include external hosts
alongside ours — the highlighted Client Hello in C3 is `SNI = www.google.com`.

If you want the frame to show only this project's handshake, filter on the
**edge** instead. `full-1.pcapng` was recorded while the edge was `10.7.31.205`
(the address in the DNS answer in the C1 screenshot; it has since moved to
`10.7.8.155` on a new lease), so against this same file:

```
ip.addr==10.7.31.205 && tcp.port==443 && tcp.len==0
ip.addr==10.7.31.205 && tls
```

No re-capture needed — the packets are already in the file, only the address in
the filter changes.

## Capture scoping, for next time

Scope at capture time rather than filtering afterwards:
**Capture → Options → Capture Filter for selected interfaces**

```
host <edge-ip> or host <dns-ip> or port 53
```

The file stays small and everything in it is relevant.
