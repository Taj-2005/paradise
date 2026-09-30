// Smoke tests for the backend contract that nginx and the evaluator rely on:
// the X-Backend header, the /api/status shape, and Cache-Control + ETag so the
// Task F "304 Not Modified" demo is actually possible.
//
// Run before deploying to both machines:
//   cd services/backend && npm test
//
// NOTE ON THE HTTP CLIENT
// These tests use node:http, not fetch(). fetch() is a *caching* client: per
// the Fetch spec it stores the first response, and when a later conditional
// request comes back 304 it transparently replays the cached body as a 200.
// You would never see the 304 on the wire. curl — which is what the evaluator
// runs — shows the real status line, and node:http behaves the same way.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';

const PORT = Number(process.env.TEST_PORT ?? 3099);
let child;

// Minimal promise wrapper over node:http — returns the raw status line and
// headers exactly as they arrived, no client-side caching in the way.
const req = (path, headers = {}) =>
  new Promise((resolve, reject) => {
    const r = http.request({ host: '127.0.0.1', port: PORT, path, method: 'GET', headers }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    r.on('error', reject);
    r.end();
  });

before(async () => {
  child = spawn(process.execPath, ['src/server.js'], {
    env: { ...process.env, BACKEND_ID: 'A', PORT: String(PORT), HOST: '0.0.0.0', CACHE_MAX_AGE: '60', TEAM: 'paradise' },
    stdio: 'ignore',
  });
  // Poll until the socket accepts rather than sleeping a fixed amount.
  for (let i = 0; i < 50; i++) {
    try { await req('/healthz'); return; } catch { await new Promise((r) => setTimeout(r, 100)); }
  }
  throw new Error('backend did not start within 5s');
});

after(() => child?.kill('SIGTERM'));

test('GET /api/status returns ok with a backend identifier', async () => {
  const res = await req('/api/status');
  assert.equal(res.status, 200);
  const body = JSON.parse(res.body);
  assert.equal(body.status, 'ok');
  assert.equal(body.backend, 'A');
});

test('every response carries X-Backend', async () => {
  for (const path of ['/', '/api/status', '/healthz', '/api/time']) {
    const res = await req(path);
    assert.equal(res.headers['x-backend'], 'A', `X-Backend missing on ${path}`);
  }
});

test('/api/status advertises Cache-Control and an ETag', async () => {
  const res = await req('/api/status');
  assert.match(res.headers['cache-control'] ?? '', /max-age=\d+/);
  assert.ok(res.headers.etag, 'ETag is required for the Task F 304 demo');
});

test('conditional request with If-None-Match returns 304 with an empty body', async () => {
  const first = await req('/api/status');
  const second = await req('/api/status', { 'If-None-Match': first.headers.etag });
  assert.equal(second.status, 304, 'Task F depends on this being 304');
  assert.equal(second.body, '', '304 must not carry a body — that is the saving');
});

test('a stale/mismatched ETag still returns a full 200', async () => {
  const res = await req('/api/status', { 'If-None-Match': 'W/"not-the-current-etag"' });
  assert.equal(res.status, 200);
});

test('the cacheable body is stable, so the ETag does not churn', async () => {
  // If /api/status embedded a live timestamp its ETag would change on every
  // request and a 304 could never happen. Guard that invariant.
  const a = await req('/api/status');
  const b = await req('/api/status');
  assert.equal(a.headers.etag, b.headers.etag);
});

test('/api/time is explicitly not cacheable', async () => {
  const res = await req('/api/time');
  assert.match(res.headers['cache-control'] ?? '', /no-store/);
});

test('unknown paths 404 as JSON, still tagged with the backend', async () => {
  const res = await req('/nope');
  assert.equal(res.status, 404);
  assert.equal(JSON.parse(res.body).backend, 'A');
});
