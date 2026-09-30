# Request flow

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/request-flow-dark.svg">
  <img alt="Request flow for one curl" src="diagrams/request-flow-light.svg">
</picture>

<sub>Source: [`request-flow.mmd`](diagrams/src/request-flow.mmd) (mermaid) · regenerate with `make diagrams`</sub>

Annotated walkthrough of one `curl https://app.paradise.test/api/status`.
The diagram above is the summary; this is the detail, with the command to
observe each stage yourself.

---

## 0 · Before anything

The client knows a **name**, nothing else. No IP, no connection, no idea the
backends exist.

---

## 1 · DNS — application layer, UDP/53

```bash
sudo dscacheutil -flushcache          # force a real query, not a cached one
dig app.paradise.test
```

```
;; QUESTION SECTION:
;app.paradise.test.        IN  A
;; ANSWER SECTION:
app.paradise.test.    0    IN  A   <EDGE_IP>
;; SERVER: <DNS_IP>#53(<DNS_IP>)
```

Two things the evaluator checks: the **ANSWER** is the edge, and the **SERVER**
is Mac 1 — not the router and not 8.8.8.8.

Observe it: `./scripts/capture.sh dns`, filter `dns`.

Still no connection to the edge. DNS is a lookup.

---

## 2 · TCP — transport layer

```
SYN      client:54821 → EDGE_IP:443     Seq=0
SYN-ACK  EDGE_IP:443  → client:54821    Seq=0 Ack=1
ACK      client:54821 → EDGE_IP:443     Seq=1 Ack=1
```

Filter: `tcp.flags.syn==1`. Note the ephemeral source port and the well-known
destination port; together with the two addresses they form the 4-tuple that
identifies this connection.

This completes **before any TLS byte is sent** — visible in the capture as
three small packets ahead of the first large one.

---

## 3 · TLS — session / presentation

```
→ ClientHello      TLS 1.3, cipher suites, SNI = app.paradise.test
← ServerHello      chosen version + cipher
← Certificate      CN/SAN = app.paradise.test, signed by our local CA
↔ Key exchange     ECDHE — the shared secret is never transmitted
→ ChangeCipherSpec
← ChangeCipherSpec, Finished
```

Filter: `tls`. After ChangeCipherSpec everything is `Application Data`.

**SNI** is sent in the clear, before encryption — the server must know which
certificate to present before it can encrypt. That is how one IP serves many
names.

```bash
curl -v https://app.paradise.test/api/status 2>&1 | grep -iE 'SSL connection|subject|issuer'
```

---

## 4 · HTTP request — inside the tunnel

```http
GET /api/status HTTP/2
Host: app.paradise.test
```

Invisible in Wireshark. That is the correct and expected result, and explaining
*why* is worth marks on form field C3.

---

## 5 · Proxy to a backend — a second, separate connection

nginx decrypts, picks a backend by round robin, and opens its **own** TCP
connection:

```
nginx:61204 → BACKEND_A_IP:3001    plain HTTP/1.1
```

```http
GET /api/status HTTP/1.1
Host: app.paradise.test
X-Forwarded-For: <client ip>
X-Forwarded-Proto: https
```

`X-Forwarded-*` is how the backend learns what the *client* asked for, given
that its socket peer is nginx. A capture on this leg is fully readable —
the contrast with step 4 is the clearest possible demonstration of what TLS
termination means.

---

## 6 · Response back out

```http
HTTP/1.1 200 OK
X-Backend: A
Cache-Control: public, max-age=60
ETag: W/"7f-..."
```

nginx passes `X-Backend` through untouched — that is the load-balancing proof —
adds `X-Upstream-Addr`, and re-encrypts for the client.

---

## 7 · The next request

| When | What happens | Network traffic |
|---|---|---|
| within 60s | served from the client's own cache | none |
| after 60s | `If-None-Match` → `304 Not Modified` | one round trip, no body |
| changed / no validator | full `200` | one round trip + body |

```bash
ETAG=$(curl -sI https://app.paradise.test/api/cacheable | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '\r')
curl -sI -H "If-None-Match: $ETAG" https://app.paradise.test/api/cacheable
```

Use `/api/cacheable`, not `/api/status` — see
[architecture.md](architecture.md#design-decisions-worth-defending-in-the-viva).

---

## Where each thing is observable

| Stage | Command | Wireshark filter |
|---|---|---|
| DNS | `dig app.paradise.test` | `dns` |
| TCP | `nc -vz app.paradise.test 443` | `tcp.flags.syn==1` |
| TLS | `curl -v …` | `tls` |
| HTTP | `curl -i …` | only on the upstream leg |
| Load balancing | `./scripts/lb-check.sh` | `http.response` on the upstream leg |
| Caching | `curl -sI …` | — |
