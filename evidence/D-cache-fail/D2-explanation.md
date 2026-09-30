# D2 — What your Cache-Control value tells the client

> Form field D2 asks for 2–4 sentences **in your own words**. The text below is
> a correct and complete answer you can adapt — but read it, understand it, and
> rephrase it. The individual viva will ask you the same thing (Q31–Q34 in
> [viva-prep.md](../../docs/viva-prep.md)) and reciting will be obvious.

## Reference answer

`Cache-Control: public, max-age=60` tells the client that this response may be
reused for 60 seconds without asking the server again, and that any shared
cache along the path may store it too. During that window the browser serves the
response from its own cache and **no network request is made at all** — not even
a conditional one.

Once 60 seconds pass the response becomes *stale*. The client does not discard
it; on the next request it revalidates by sending `If-None-Match` with the ETag
it stored. If the resource has not changed the server replies **304 Not
Modified** with headers but no body, and the client reuses what it already has.
That costs one round trip instead of the full payload. If the resource *has*
changed, the server sends a normal 200 with the new body and a new ETag.

## The three cases, distinguished

| | Network cost | Status |
|---|---|---|
| Fresh cache hit (< 60s) | nothing | no request made |
| Conditional request (> 60s, unchanged) | one round trip, no body | 304 |
| Full request (changed, or no validator) | one round trip + body | 200 |

## Bonus — the ETag detail worth mentioning

Our ETag is weak (`W/"..."`), meaning semantic rather than byte-for-byte
equivalence — sufficient for cache validation.

We demonstrate the 304 against `/api/cacheable` rather than `/api/status`, and
the reason is a genuine distributed-systems constraint: `/api/status` includes
the backend's identity in its body, so Backend A and Backend B compute
**different ETags for the same resource**. With round-robin load balancing a
conditional request frequently lands on the other replica, which does not
recognise the validator and returns a full 200 — so the 304 would appear only
about half the time. `/api/cacheable` returns a byte-identical body on both
backends, so every replica derives the same ETag and revalidation is
deterministic.

The general rule: **cache validators must agree across replicas, or conditional
requests silently degrade into full responses.**
