import { Router } from 'express';
import { config } from '../config.js';
import { cacheHeaders } from '../middleware/cacheHeaders.js';

// GET /api/cacheable — the endpoint the Task F conditional-request demo uses.
//
// ── WHY THIS EXISTS (worth understanding for the viva) ────────────────────
//
// An ETag is a hash of the response body. Express computes it per-process,
// from the bytes it is about to send.
//
// /api/status is REQUIRED by the spec to identify which backend answered:
//     { "backend": "A", ... }   on Mac 3
//     { "backend": "B", ... }   on Mac 4
// Different bytes -> different ETag on each replica.
//
// Now add round-robin load balancing. The client does:
//     1. GET /api/status          -> lands on A, gets ETag_A
//     2. GET with If-None-Match: ETag_A  -> lands on B
// B compares ETag_A against its own ETag_B, sees no match, and returns a full
// 200. The 304 you were trying to demonstrate never happens — and it fails
// intermittently, which is the worst kind of failure to hit on camera.
//
// This is a real distributed-systems problem, not a toy one: conditional
// requests only work behind a load balancer if every replica derives the same
// validator for the same resource. Production fixes are to seed the ETag from
// content (a build hash, a DB row version) rather than from process state, or
// to pin the client to one replica with sticky sessions.
//
// Our fix is the first one: this body is byte-identical on every backend, so
// every replica computes the same ETag and the 304 is deterministic no matter
// which machine the request lands on.
//
// X-Backend is still set on the response (it is a header, not part of the
// body), so you can STILL see which backend served each 304 — which makes the
// point beautifully on camera: same ETag, same 304, different server.
export const cacheableRouter = Router();

cacheableRouter.get('/api/cacheable', cacheHeaders, (req, res) => {
  res.json({
    resource: 'cn-phase1-cacheable-document',
    team: config.team,
    version: 1,
    note: 'Body is identical on every backend so the ETag matches across replicas.',
  });
});
