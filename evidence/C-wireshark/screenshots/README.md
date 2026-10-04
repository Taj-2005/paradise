# Wireshark screenshots

Naming: `C<n>-<what-it-shows>.png` — the form field first, so the right image is
obvious when filling in Section C.

## Usable

| File                                 | Shows                                                                                                                                                                 | Proves                                                                                                          |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `C1-dns-response-answer-section.png` | DNS response packet detail: IPv4 `10.7.27.161` → `10.7.26.203`, UDP src port 53 → 56279, Answers: `app.paradise.test type A addr 10.7.8.155`, Transaction ID `0xba40` | The client resolved our private name through **our own** DNS server, and the answer is the edge — not a backend |

## Still needed

| File                             | Filter                                               | Must show                                                      |
| -------------------------------- | ---------------------------------------------------- | -------------------------------------------------------------- |
| `C2-tcp-three-way-handshake.png` | `ip.addr==10.7.8.155 && tcp.port==443 && tcp.len==0` | SYN / SYN-ACK / ACK between `10.7.26.203` and `10.7.8.155:443` |
| `C3-tls-clienthello-sni.png`     | `ip.addr==10.7.8.155 && tls`                         | Client Hello with **SNI = app.paradise.test**                  |
| `C3-tls-serverhello-cipher.png`  | same                                                 | Server Hello with the negotiated cipher suite                  |

## `_not-usable/` — why those six were rejected

They capture this laptop's **background internet traffic**, not the paradise
network. The display filters (`tcp.flags.syn==1`, `tls`) were correct, but with
no address restriction they matched every connection the Mac was making:

| File                                   | Destination                       | Problem                                             |
| -------------------------------------- | --------------------------------- | --------------------------------------------------- |
| `tcp-syn-list-external-hosts-only.png` | `142.251.x`, `51.132.x`, `17.8.x` | Google, Microsoft, Apple — our edge appears nowhere |
| `tcp-syn-detail-dst-microsoft.png`     | `51.132.193.109`                  | Microsoft, not `10.7.8.155`                         |
| `tls-list-google-traffic.png`          | `142.250.x`                       | Google                                              |
| `tls-list-google-serverhello.png`      | `142.250.183.234`                 | Google                                              |
| `tls-clienthello-sni-google.png`       | `142.250.183.234`                 | **SNI = peoplestack-pa.clients6.google.com**        |
| `tls-serverhello-dst-google.png`       | `142.250.183.234`                 | Google                                              |

The capture held **50,760 packets**, of which 7,296 matched `tls` — almost all
of it noise. Submitting these would show an evaluator a TLS handshake with
Google, which proves nothing about this project.

## How to avoid it when re-capturing

**Scope the capture itself**, not just the display. In Wireshark:
**Capture → Options → Capture Filter for selected interfaces**, enter:

```
host 10.7.8.155 or host 10.7.27.161 or port 53
```

Only our own traffic is recorded, so the file is small and everything in it is
relevant. Then apply the display filters above.

If you already have a big capture, add the address to the display filter
instead — `ip.addr==10.7.8.155 && tls` — and the noise disappears.
