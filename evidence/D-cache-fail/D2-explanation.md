# D2 — What your Cache-Control value tells the client

Form field D2 asks for 2–4 sentences explaining the `Cache-Control` value we set.

## Our answer

We set `Cache-Control: public, max-age=60` on `/api/status` and `/api/cacheable`.
That tells the client it may reuse the response for 60 seconds without contacting
the server at all — during that window the browser serves it straight from its own
cache and nothing goes over the network, not even a conditional request. Once the
60 seconds pass the response is stale, but the client does not throw it away: on
the next request it sends `If-None-Match` carrying the ETag it stored. If nothing
has changed the server replies `304 Not Modified` with headers and no body, so we
spend one round trip instead of re-downloading the whole payload; if the resource
has changed we get a normal `200` with a new ETag and the new content.

## The three cases, distinguished

| | Network cost | Status |
|---|---|---|
| Fresh cache hit (< 60s) | nothing | no request made |
| Conditional request (> 60s, unchanged) | one round trip, no body | 304 |
| Full request (changed, or no validator) | one round trip + body | 200 |

## Showing it

```bash
# the header that makes the promise
curl -sI https://app.paradise.test/api/cacheable

# capture the validator, then ask again with it
ETAG=$(curl -sI https://app.paradise.test/api/cacheable \
  | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '\r')
curl -si -H "If-None-Match: $ETAG" https://app.paradise.test/api/cacheable
```

The second request returns `304` with headers and an empty body. That contrast —
full payload versus no payload — is the whole point of the header.

## Why we demonstrate the 304 on `/api/cacheable`

Worth mentioning, because it is a real constraint rather than a workaround.

`/api/status` has to identify which backend answered, so Backend A and Backend B
return different bodies and therefore compute **different ETags for the same
resource**. With round-robin load balancing a conditional request frequently lands
on the other replica, which does not recognise the validator and returns a full
200 — so the 304 would show up only about half the time.

`/api/cacheable` returns a byte-identical body on both backends, so every replica
derives the same ETag and revalidation is deterministic. `X-Backend` is still on
the response, so it stays visible which machine served each 304.

The general rule: **cache validators must agree across replicas, or conditional
requests silently degrade into full responses.**
