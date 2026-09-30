import { Router } from 'express';
import { config } from '../config.js';
import { noCache } from '../middleware/cacheHeaders.js';

export const healthRouter = Router();

// GET /healthz — liveness probe for nginx.
//
// Phase 1: open-source nginx has passive health checks only. It marks an
// upstream down after `max_fails` connection errors within `fail_timeout`
// and stops sending traffic there — which is exactly what makes the
// "kill Backend A" failure demo (spec §6.3) work without any 502s.
//
// Phase 2 Extension D can poll this actively. Never cached: a cached health
// check is a lie about the present.
healthRouter.get('/healthz', noCache, (req, res) => {
  res.json({ status: 'healthy', backend: config.backendId, uptimeSeconds: Math.floor(process.uptime()) });
});

// GET /api/time — deliberately uncacheable, the contrast case for the Task F
// explanation. Compare `curl -sI /api/status` against `curl -sI /api/time`:
// same server, opposite caching instructions.
healthRouter.get('/api/time', noCache, (req, res) => {
  res.json({ backend: config.backendId, now: new Date().toISOString(), uptimeSeconds: process.uptime() });
});
