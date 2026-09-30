// CN Phase 1 — Backend service.
//
// The spec is explicit that the application is NOT what is being marked:
//   "Keep the application code minimal — the networking configuration is what
//    matters here, not the app's features."  (spec §6, Task C)
//
// So this file does exactly four things: set the X-Backend header, expose the
// two required endpoints, add cache headers, and bind to a LAN-reachable
// interface. Everything else is left out on purpose.

import express from 'express';
import { config } from './config.js';
import { backendHeader } from './middleware/backendHeader.js';
import { requestLog } from './middleware/requestLog.js';
import { rootRouter } from './routes/root.js';
import { statusRouter } from './routes/status.js';
import { healthRouter } from './routes/health.js';
import { cacheableRouter } from './routes/cacheable.js';

const app = express();

// Tell Express it sits behind nginx, so req.ip and req.protocol reflect the
// X-Forwarded-For / X-Forwarded-Proto headers the edge sets rather than
// nginx's own address. Matters for the access log being truthful.
app.set('trust proxy', true);

// Weak ETags over response bodies. This is what makes 304 Not Modified work
// for the Task F conditional-request demo.
app.set('etag', 'weak');

// Hide the "X-Powered-By: Express" header — it is noise in curl -v output
// during evaluation and leaks the stack for no benefit.
app.disable('x-powered-by');

app.use(requestLog);
app.use(backendHeader);

app.use(rootRouter);
app.use(statusRouter);
app.use(healthRouter);
app.use(cacheableRouter);

app.use((req, res) => {
  res.status(404).json({ error: 'Not Found', backend: config.backendId, path: req.originalUrl });
});

// eslint-disable-next-line no-unused-vars -- Express identifies error handlers by arity (4 args)
app.use((err, req, res, next) => {
  console.error(`[${config.backendId}] unhandled:`, err);
  res.status(500).json({ error: 'Internal Server Error', backend: config.backendId });
});

const server = app.listen(config.port, config.host, () => {
  const line = '─'.repeat(52);
  console.log(`\n${line}`);
  console.log(`  CN Phase 1 — Backend ${config.backendId}`);
  console.log(line);
  console.log(`  listening   http://${config.host}:${config.port}`);
  console.log(`  hostname    ${config.hostname}`);
  console.log(`  cache       Cache-Control: public, max-age=${config.cacheMaxAge}`);
  console.log(`  endpoints   GET /            GET /api/status`);
  console.log(`              GET /healthz     GET /api/time`);
  console.log(`${line}`);
  console.log(`  Bound to ${config.host} — reachable from the LAN, not just`);
  console.log(`  this laptop. nginx on the edge machine proxies to it.`);
  console.log(`${line}\n`);
});

// Clean shutdown so that Ctrl-C during the failure demo drops the listening
// socket immediately. Without this the port can linger and the "restart
// Backend A" half of the demo fails with EADDRINUSE on camera.
const shutdown = (signal) => {
  console.log(`\n[${config.backendId}] ${signal} received — closing server.`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 3000).unref();
};
process.on('SIGINT',  () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
