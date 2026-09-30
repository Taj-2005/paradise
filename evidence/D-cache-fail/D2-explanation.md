# D2 — What your Cache-Control value tells the client

Form field D2 asks for **2–4 sentences in your own words**. Write them here,
then paste them into the form.

The same question comes back in the individual viva (Q31–Q34 in
[docs/viva-prep.md](../../docs/viva-prep.md)), so write something you can say
aloud without notes.

## Our answer

> <<< WRITE 2–4 SENTENCES HERE >>>

## What a complete answer covers

Use this as a checklist, not as text to copy.

- [ ] What `max-age=60` means — the client may reuse the response for 60
      seconds without contacting the server at all.
- [ ] What the client does with that — serves from its own cache; **no network
      request is made**, not even a conditional one.
- [ ] What happens when the TTL expires — the response goes *stale* but is not
      discarded; the client revalidates with `If-None-Match`.
- [ ] Bonus: what a **304 Not Modified** means — headers but no body, so one
      round trip instead of the full payload; and when it occurs.

## The three cases, distinguished

| | Network cost | Status |
|---|---|---|
| Fresh cache hit (< 60s) | nothing | no request made |
| Conditional request (> 60s, unchanged) | one round trip, no body | 304 |
| Full request (changed, or no validator) | one round trip + body | 200 |

## Why we demonstrate the 304 on `/api/cacheable`

Worth mentioning in the form and the viva, because it is a real constraint
rather than a workaround.

`/api/status` must identify which backend answered, so Backend A and Backend B
return different bodies and therefore compute **different ETags for the same
resource**. With round-robin load balancing a conditional request frequently
lands on the other replica, which does not recognise the validator and returns
a full 200 — so the 304 would appear only about half the time.

`/api/cacheable` returns a byte-identical body on both backends, so every
replica derives the same ETag and revalidation is deterministic.

The general rule: **cache validators must agree across replicas, or conditional
requests silently degrade into full responses.**
