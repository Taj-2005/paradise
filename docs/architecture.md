# Architecture

## Topology

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/topology-dark.svg">
  <img alt="CN Phase 1 network topology" src="diagrams/topology-light.svg">
</picture>

<sub>Source: [`topology.mmd`](diagrams/src/topology.mmd) (mermaid) · regenerate with `make diagrams`</sub>

Four macOS laptops on one private LAN, in a single `/24`. No router configuration,
no VLANs, no cloud. Every machine can reach every other machine directly; the
structure comes from *which service runs where*, not from the physical network.

| Machine | Role | Services | Ports | Cloud equivalent |
|---|---|---|---|---|
| Mac 1 | Private DNS + test client | dnsmasq | 53 (UDP/TCP) | Route 53 private hosted zone |
| Mac 2 | Edge: reverse proxy, load balancer, TLS terminator | nginx | 80/443 (or 8080/8443) | ALB + ACM certificate |
| Mac 3 | Backend A | Express | 3001 | EC2 in an ALB target group |
| Mac 4 | Backend B + test client | Express | 3002 | EC2 in an ALB target group |

Real IP addresses live in `.env` and nowhere else. Run `./scripts/status.sh`
on any machine to print the live inventory.

## Request flow

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/request-flow-dark.svg">
  <img alt="Request flow for one curl" src="diagrams/request-flow-light.svg">
</picture>

<sub>Source: [`request-flow.mmd`](diagrams/src/request-flow.mmd) (mermaid) · regenerate with `make diagrams`</sub>

A single `curl https://app.paradise.test/api/status` touches four protocols in
order. Each is independently observable, and each fails in a distinguishable way
— which is the whole point of the exercise.

### 1 · DNS — application layer, UDP/53

The client asks Mac 1 for an A record. Mac 1 is authoritative for
`*.paradise.test` and answers `EDGE_IP`. Anything else it forwards upstream, so
the client keeps normal internet access.

Nothing has connected to the edge yet. DNS is a **directory lookup**, not a
connection — the cleanest way to see this is the Option B failure demo, where
breaking resolution leaves IP connectivity completely intact.

### 2 · TCP — transport layer

The client opens a TCP connection from an ephemeral port to `EDGE_IP:443`.
SYN → SYN-ACK → ACK. This completes before a single byte of TLS is sent, which
is visible in Wireshark with `tcp.flags.syn==1`.

The handshake establishes a reliable, ordered, connection-oriented channel:
sequence numbers let either side detect loss and reorder; the window field
provides flow control.

### 3 · TLS — between transport and application

ClientHello (with SNI set to `app.paradise.test`) → ServerHello + Certificate →
key exchange → ChangeCipherSpec. After that, every frame is `Application Data`.

**TLS terminates at Mac 2.** The client's encrypted session ends there. This is
exactly what an ALB with an ACM certificate does, and it is why a capture shows
unreadable bytes on the client leg and readable HTTP on the upstream leg.

SNI is why one IP and one port can serve many names. It also means the
certificate must carry a **Subject Alternative Name** matching the requested
host — a CN-only certificate is rejected by every modern client.

### 4 · HTTP — application layer

nginx decrypts, picks a backend by round robin, and issues a **separate,
plaintext HTTP/1.1 request** over its **own TCP connection** to `:3001` or
`:3002`. The backend's `X-Backend` header rides back through the proxy
untouched, which is what makes load balancing visible.

## Two connections, not one

The most useful thing to understand about this architecture:

| | client → edge | edge → backend |
|---|---|---|
| Protocol | HTTPS (TLS 1.2/1.3) | plain HTTP/1.1 |
| Destination port | 443 / 8443 | 3001 / 3002 |
| Source port | client ephemeral | nginx ephemeral |
| Encrypted? | yes | no |
| Readable in Wireshark? | no | yes |
| Lifetime | per client request | pooled and reused (`keepalive 16`) |

They are entirely independent TCP sessions with their own handshakes.

## Why the client never learns the backend addresses

DNS only ever returns Mac 2. nginx is the only thing the client connects to. The
backends could be renumbered, moved, or scaled to ten machines without the client
noticing.

That indirection is what a reverse proxy buys you, and it is what makes Phase 2's
service isolation possible: once nothing but Mac 2 needs to reach `:3001`, you can
firewall those ports shut.

## Failure isolation

Each layer fails differently, and telling them apart is the diagnostic skill the
project is really testing.

| Break | DNS | TCP to edge | TLS | Response | Layer |
|---|---|---|---|---|---|
| Backend A stopped | ok | ok | ok | 200, all from B | application |
| Both backends stopped | ok | ok | ok | **502** from nginx | application (upstream) |
| Wrong client resolver | **NXDOMAIN** | n/a | n/a | curl cannot resolve | application (DNS) |
| Wrong port (`:9999`) | ok | **refused** | n/a | connection refused | transport |
| nginx stopped | ok | **refused** | n/a | connection refused | transport/application |
| CA not trusted | ok | ok | **fails** | cert verify error | session/presentation |

Work top down: resolve, then connect, then handshake, then request. The first
step that fails names the layer.

## Design decisions worth defending in the viva

**`.test`, not `.local`.** `.local` is claimed by macOS mDNS/Bonjour; using it
produces intermittent resolution that looks like a dnsmasq bug. `.test` is
reserved by RFC 6761 precisely for this.

**Backends bind `0.0.0.0`.** Binding `127.0.0.1` makes a backend reachable from
its own laptop and invisible to nginx — every proxied request 502s while local
testing looks perfect. `src/config.js` refuses to start on loopback.

**TTL 0 in Phase 1.** Deterministic demos: no client holds a stale answer
mid-recording. Phase 2 Extension B raises it to 30 in order to *demonstrate*
stale caching.

**A separate `/api/cacheable` endpoint.** `/api/status` must identify its
backend, so its body — and therefore its ETag — differs between replicas. Behind
round robin, a conditional request often lands on the *other* backend, sees a
non-matching ETag, and returns 200 instead of 304. `/api/cacheable` has a
byte-identical body on both machines, so the 304 is deterministic. This is a real
distributed-caching constraint, not a workaround: validators must agree across
replicas or conditional requests break.

**Requests by IP are refused.** `nginx.conf` has a `default_server` returning
`444`, so the spec's "by name, never by IP" rule is enforced by the server rather
than by discipline.

## Single point of failure

**Mac 2.** Every request goes through it, and it holds the only certificate.
If it dies, DNS still resolves and the backends are still healthy, but nothing
is reachable.

Eliminating it needs a second edge with the same cert plus a way to move traffic
— a floating IP, or a DNS record with a short TTL. Phase 2 Extension E does the
DNS-based version. Naming this unprompted scores marks.
