# OSI and TCP/IP mapping

Spec §6.1 asks you to map DNS, HTTP, TLS, TCP/UDP, IP and Ethernet to the
correct layers, for **this** project rather than in the abstract.

## The single request, layer by layer

| OSI | TCP/IP | Protocol here | Where it runs | Identifier | Observable as |
|---|---|---|---|---|---|
| 7 Application | Application | **DNS** | Mac 1 dnsmasq | port 53 | `dig`; Wireshark `dns` |
| 7 Application | Application | **HTTP/1.1, HTTP/2** | Mac 2 → Mac 3/4 | method + path | `curl -v`; readable only on the upstream leg |
| 6 Presentation | Application | **TLS record layer** | Mac 2 nginx | — | Wireshark `tls`, "Application Data" |
| 5 Session | Application | **TLS handshake / session** | Mac 2 nginx | session ID / ticket | ClientHello … Finished |
| 4 Transport | Transport | **TCP** (HTTP), **UDP** (DNS) | every machine | port numbers | `tcp.flags.syn==1` |
| 3 Network | Internet | **IPv4** | every machine | IP address | `ping`, `ip.addr` |
| 2 Data Link | Link | **Ethernet / 802.11** | Wi-Fi | MAC address | `ifconfig en0 | grep ether` |
| 1 Physical | Link | 2.4/5 GHz radio | Wi-Fi | — | signal strength |

TLS is the awkward one. OSI splits it: session establishment at 5, encryption
and encoding at 6. TCP/IP has no equivalent split and simply calls the whole
thing "application". Saying *"TLS sits above TCP and below HTTP; OSI splits it
across 5 and 6, TCP/IP folds it into the application layer"* is the complete
answer.

## Ports actually in use

| Port | Protocol | Transport | Who listens | Why this one |
|---|---|---|---|---|
| 53 | DNS | UDP (TCP fallback) | Mac 1 | Well-known. UDP because queries are small and a lost one is just retried — the latency cost of a handshake is not worth it. |
| 443 / 8443 | HTTPS | TCP | Mac 2 | Well-known for HTTP over TLS. 8443 when binding below 1024 is not possible; the spec allows it with no penalty. |
| 80 / 8080 | HTTP | TCP | Mac 2 | Redirects to HTTPS. |
| 3001 | HTTP | TCP | Mac 3 | Registered range, arbitrary but fixed. |
| 3002 | HTTP | TCP | Mac 4 | Same. |
| ephemeral (49152–65535) | — | TCP/UDP | clients | Assigned per connection by the OS. |

## Socket pairs in one request

A connection is identified by a **4-tuple**, not by a port alone:

```
client → edge     (10.0.0.21, 54821)  ↔  (10.0.0.11, 443)
edge   → backend  (10.0.0.11, 61204)  ↔  (10.0.0.12, 3001)
```

Two different connections. Six concurrent curls would produce six different
client-side tuples all sharing `:443` on the edge — which is exactly how one
listening port serves many clients at once (transport-layer demultiplexing).

## Why DNS uses UDP and HTTP uses TCP

| | DNS over UDP | HTTP over TCP |
|---|---|---|
| Message size | small, one datagram | arbitrary, streamed |
| Cost of loss | resend the query | must not lose bytes |
| Handshake | none — 1 round trip total | 3-way, before any data |
| Ordering | irrelevant, one message | essential |
| State | none | connection state both ends |

A DNS handshake would double resolution latency for a message that fits in one
packet. HTTP without TCP's reliability would mean corrupt responses.

## Where each course topic shows up

| Week | Topic | Where it appears |
|---|---|---|
| 1–2 | Edge vs core, packet switching | Client → edge → backend; every hop store-and-forward |
| 1–2 | Delay, loss, throughput | `ping` RTT, `$request_time` vs `$upstream_response_time` in the nginx log |
| 1–2 | Devices, topologies | Star topology via the AP; nginx as an L7 load balancer |
| 3–4 | HTTP/1.1 vs HTTP/2 | `http2 on`; `curl --http1.1` to compare |
| 3–4 | HTTPS, TLS handshake | Task E, Wireshark `tls` |
| 3–4 | DNS records, resolution | Task B, A records in `dnsmasq.conf` |
| 3–4 | CDN and caching | Task F, `Cache-Control` + `ETag` + 304 |
| 3–4 | REST | `/api/status` returning JSON |
| 3–4 | Route 53 | dnsmasq as the private-hosted-zone analogue |
| 5–6 | Mux/demux, ports | The socket-pair table above |
| 5–6 | UDP vs TCP | DNS on 53/UDP, HTTP on 443/TCP |
| 5–6 | 3-way handshake | Task G, `tcp.flags.syn==1` |
| 5–6 | Reliable data transfer | Seq/Ack numbers in the capture |
| 5–6 | Flow control | TCP window field |
| 5–6 | ALB vs NLB | nginx is L7 (reads `Host`, routes on path) = ALB. An L4 NLB would forward TCP without seeing HTTP. |
| 5–6 | ELB health checks | `max_fails` / `fail_timeout`; `/healthz` |

## Out of scope for mid-sem

Weeks 7–12 — CIDR subnetting, NAT, DHCP, IPv6, Dijkstra/Bellman-Ford, RIP/OSPF/BGP,
ARP and Ethernet framing, CRC, Wi-Fi PHY, VPC peering, CloudFront internals —
are **not** required here. Phase 1 deliberately stays inside Weeks 1–6.
