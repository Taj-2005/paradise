# Demo day: the spec §8 sequence, step by step

The faculty can stop at any step and ask anyone. Every member must be able to
explain every step, not only the one they type.

## 30 minutes before

| Who | Run | Why |
|---|---|---|
| **everyone** | `caffeinate -dims &` | A sleeping Mac still answers ping but freezes nginx/node (report §3.2, Incident 1). This happened twice on 23 Nov. |
| **everyone** | `ipconfig getifaddr en0` | If any address differs from [ip-inventory.md](ip-inventory.md): update `.env`, `make render` everywhere, `make dns` (Mac 1), `make edge` (Mac 2) |
| Mac 3 / Mac 4 | `make backend-a` / `make backend-b` | leave the terminals visible |
| Mac 1 | `make p2-primary-dns` · Mac 4: `make p2-backup-dns`, `make p2-standby-edge` | Phase 2 profiles (TTL 30, backup, standby) |
| Mac 3, Mac 4 | `make p2-isolate` | pf isolation (Ext C) |
| **Nipun (Mac 1)** | `make verify` then `make p2-verify` | Phase 1 + Phase 2 acceptance; both must be all-pass before you start |

## The 11 steps

| # | Spec step | Who | Command | What to point at | Evidence if asked |
|---|---|---|---|---|---|
| 1 | Topology and IP/service inventory | Nipun | open [project.html](project.html), [ip-inventory.md](ip-inventory.md), README topology | each role, its IP, its port, its cloud equivalent | `docs/diagrams/`, [architecture.md](architecture.md), [phase2/architecture.md](phase2/architecture.md) |
| 2 | All machines on the LAN | everyone | `make preflight` on each Mac | 0% loss to each peer, own IP printed | `evidence/A-lan-dns/A1-ips.txt`, `A5-ping-matrix.txt` |
| 3 | Resolve from a client | Tajuddin (Mac 3) | `dig app.paradise.test` | `ANSWER: 10.7.3.123`, `SERVER: 10.7.20.228#53`, TTL 30 | `A3-dig-client.txt`, `A4-dig-8888.txt` (NXDOMAIN publicly) |
| 4 | HTTPS by name, no warning | Tajuddin | `curl -v https://app.paradise.test/api/status` (**never `-k`**) | `SSL certificate verify ok`, `subject: CN=app.paradise.test`, `HTTP/2 200` | `B1-curl-verbose.txt` |
| 5 | Load balancing | Omkar (Mac 4) | `make lb` | `X-Backend: A` and `B` alternating | `B2-lb-6x.txt`, `phase2/D-ha-failover/D1-steady-state-lb.txt` |
| 6 | Wireshark: DNS, TCP, TLS | Omkar | `open -a Wireshark evidence/captures/full-1.pcapng`, filter `dns \|\| tcp.flags.syn==1 \|\| tls.handshake` | DNS query/answer on 53/UDP; SYN, SYN-ACK, ACK with the ephemeral port → 443; ClientHello (SNI), ServerHello; encrypted Application Data | `evidence/C-wireshark/C1–C3.md` + screenshots |
| 7 | Headers and caching | Anushka (Mac 2 view) or any client | `curl -sI https://app.paradise.test/api/cacheable` then repeat with `-H 'If-None-Match: <etag>'` | `cache-control: public, max-age=60`, `etag`, then **`304 Not Modified`** | `D1-headers.txt`, `D2-explanation.md` (why `/api/cacheable`, not `/api/status`) |
| 8 | Fail one backend | Tajuddin stops A · Nipun runs `make p2-ha-demo` · Anushka runs `make p2-health-watch` | Ctrl-C Backend A at ~15 s, `make backend-a` at ~45 s | all `HTTP 200`, B-only window, `upstream=A, B` retries, A rejoins | `phase2/D-ha-failover/D-ha-demo-20261123-124350.txt` (145 req, 0 errors) |
| 9 | Phase 2 DNS resilience | Nipun + Omkar | **A:** Mac 1 `make p2-dns-stop`, Mac 3 `make p2-demo-dns-failover`, then `make p2-dns-start` · **B/E:** Mac 3 `make p2-ttl-watch`; Mac 1 **and** Mac 4 `make p2-cutover TO=standby`; later `TO=primary` + `make p2-flush` | A: `SERVER: 10.7.18.17` while curl stays 200 · B/E: `STALE` rows, then `CUT OVER after Ns`, `X-Edge` changes | `phase2/A-backup-dns/`, `phase2/B-ttl/`, screenshots W-A1/W-A2/W-B2-E1 |
| 10 | Faculty-injected fault | whoever is at the affected Mac; Nipun narrates | `make p2-diagnose` from a client, then confirm by hand: `dig` → `nc -vz app.paradise.test 443` → `curl -v` → `curl -i` | the **first** failing layer; timeout vs refused; check the standby edge and both DNS servers | report §4; `phase2/F-troubleshooting/` |
| 11 | Individual viva | everyone | — | see the question list below | — |

**After step 9, cut back before step 10.** Both DNS servers must point at Mac 2:
`dig +short @10.7.20.228 app.paradise.test` and `@10.7.18.17` must both say
`10.7.3.123` (report §3.1 Ext E, Incident 4).

**During step 10**, the edge's site log is
`/opt/homebrew/var/log/nginx/paradise-error.log`. The global `error.log` is the
wrong file.

## Viva: questions to be able to answer without notes

**Phase 1**
- What is the difference between DNS resolution and the TCP/HTTPS connection that follows?
- Why does the client never need the backend IPs?
- Walk through ClientHello → ServerHello → Certificate → key exchange → Finished. Where does trust come from?
- Why is the HTTP payload unreadable in Wireshark? Where is TLS terminated?
- Fresh cache hit vs conditional request (304) vs full request. Why does the 304 demo use `/api/cacheable`?
- Map DNS, HTTP, TLS, TCP/UDP, IP and Ethernet onto OSI and TCP/IP.
- Which socket pair does one request use? Which port is ephemeral?
- Explain the sequence and acknowledgement numbers in the handshake.

**Phase 2**
- How does a client fall through to the backup DNS? (same query ID re-sent after ~1 s)
- Why does the backup not forward to the primary?
- Why was the stale window 9–11 s and not 30 s? Why lower the TTL *before* a migration?
- FILTERED vs CLOSED: what does each look like in Wireshark?
- How does open-source nginx detect a dead backend? What do `max_fails`, `fail_timeout` and `proxy_next_upstream` each do?
- Why did we get 502s during failover, and why does the keep-alive timer order fix it?
- What is still a single point of failure, and what removes it (VRRP/VIP, health-checked DNS, anycast)?
- Why must the old edge stay up during a cutover?
- Why can TCP "succeed" to an IP with no host behind it on the campus network?

## After the evaluation

```bash
make p2-rollback          # each Mac: restores dnsmasq, resolvers, pf, stops the standby
make p2-status            # confirm nothing Phase 2 is left
killall caffeinate
```
