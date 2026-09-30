import { Router } from 'express';
import { config } from '../config.js';
import { cacheHeaders } from '../middleware/cacheHeaders.js';

// GET /api/status — the endpoint the whole demo revolves around.
//
// Spec Task C requires: JSON with status and a clear backend identifier,
//   e.g. { "backend": "A", "status": "ok" }
//
// Task F requires cache headers here, and Express adds a weak ETag over the
// JSON body automatically. Those two facts interact, so read this carefully:
//
//   If the body changed on every request (a live timestamp, an uptime counter)
//   the ETag would change every time and a conditional request could NEVER
//   return 304. The caching demo would silently be impossible to show.
//
// So the cacheable fields are STABLE for the life of the process, and the
// volatile values live on /api/time instead, which is explicitly no-store.
export const statusRouter = Router();

statusRouter.get('/api/status', cacheHeaders, (req, res) => {
  res.json({
    status: 'ok',
    backend: config.backendId,
    team: config.team,
    host: config.hostname,
    port: config.port,
    startedAt: config.startedAt,
  });
});
