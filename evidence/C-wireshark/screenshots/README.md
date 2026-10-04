# Wireshark screenshots

Naming: `C<n>-<what-it-shows>.png` — the form field first, so the right image is
obvious when filling in Section C. All taken from
[`../../captures/full-1.pcapng`](../../captures/full-1.pcapng).

## Usable

| File | Filter used | Shows |
|---|---|---|
| `C1-dns-query-response-list.png` | `dns && ip.addr==10.7.27.161` | The packet list with our query and its answer: `Standard query 0x9969 A app.paradise.test` and `Standard query response 0x9969 A app.paradise.test A 10.7.31.205` |
| `C1-dns-response-answer-section.png` | same, response packet expanded | Packet detail: IPv4 `10.7.27.161` → `10.7.26.203`, UDP src port 53 → 56279, `Answers: app.paradise.test type A addr 10.7.31.205`, Transaction ID `0xba40` |

Together these cover C1 completely — the list view shows the query/response
pair, the detail view proves the source, destination, port and answer record.

## Wrong filter — re-shoot these two

| File | Filter used | What went wrong |
|---|---|---|
| `C2-tcp-syn-WRONG-FILTER-client-ip.png` | `ip.addr==10.7.26.203 && tcp.port==443 && tcp.len==0` | `10.7.26.203` is **this Mac**, not the edge. Every connection the laptop makes matches, so the SYNs shown go to Google and other external hosts. |
| `C3-tls-WRONG-FILTER-client-ip.png` | `ip.addr==10.7.26.203 && tls` | Same mistake. The highlighted Client Hello reads **`SNI = www.google.com`**. |

Filtering on the client matches *all* of its traffic. The filter has to name the
**edge**, which is the only address that isolates this project's HTTPS session.

### The fix — no re-capture needed

`full-1.pcapng` was recorded while the edge was **10.7.31.205** (that is the
address in the DNS answer visible in the C1 screenshot — it has since moved to
10.7.8.155 on a new DHCP lease). So re-open the same file and use:

```
ip.addr==10.7.31.205 && tcp.port==443 && tcp.len==0     → C2
ip.addr==10.7.31.205 && tls                             → C3
```

For C3 look for `Client Hello` with **`SNI = app.paradise.test`**. If that row is
not there, the capture does not contain the HTTPS session and a fresh capture is
needed — scope it at capture time with
`host <edge-ip> or host <dns-ip> or port 53` so only our traffic is recorded.

## Why the address matters

A display filter with no address restriction, or one naming the capturing
machine, matches everything the laptop is doing — background sync, browser
tabs, OS telemetry. An earlier attempt produced six screenshots this way and
every one of them captured somebody else's TLS handshake. Always name the
**other end** of the connection you are trying to show.
