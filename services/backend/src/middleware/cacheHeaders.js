import { config } from '../config.js';

// Task F — HTTP caching.
//
// Cache-Control: public, max-age=N
//   Tells the client (and any shared cache/CDN in between) that this response
//   may be reused without re-asking the server for N seconds. Within that
//   window the browser serves from its own cache — zero network traffic.
//
// After max-age expires the response is "stale". The client does not throw it
// away; it revalidates with a conditional request:
//      GET /api/status
//      If-None-Match: "<etag>"
// If the resource has not changed the server replies 304 Not Modified with an
// empty body — saving the payload but still costing one round trip.
//
// Express computes a weak ETag for JSON bodies automatically and handles the
// If-None-Match comparison itself, so we only have to set Cache-Control.
export function cacheHeaders(req, res, next) {
  res.setHeader('Cache-Control', `public, max-age=${config.cacheMaxAge}`);
  next();
}

// Contrast case, so the demo can show BOTH behaviours side by side:
// an endpoint that must never be cached.
export function noCache(req, res, next) {
  res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate');
  next();
}
