import { Router } from 'express';
import { config } from '../config.js';
import { cacheHeaders } from '../middleware/cacheHeaders.js';

// GET /  — spec Task C: "A basic page or JSON object confirming the service
// is running." Content-negotiated: a browser gets HTML, curl gets JSON.
export const rootRouter = Router();

rootRouter.get('/', cacheHeaders, (req, res) => {
  const payload = {
    service: `CN Phase 1 Backend ${config.backendId}`,
    backend: config.backendId,
    team: config.team,
    host: config.hostname,
    port: config.port,
    message: 'Service is running. Try GET /api/status',
  };

  res.format({
    'application/json': () => res.json(payload),
    'text/html': () => res.send(html(payload)),
    default: () => res.json(payload),
  });
});

const html = (p) => `<!doctype html>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Backend ${p.backend} — ${p.team}</title>
<style>
  :root{color-scheme:light dark}
  body{font:16px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;
       display:grid;place-items:center;min-height:100vh;margin:0;
       background:#0b1220;color:#e6edf6}
  .card{border:1px solid #2a3a55;border-radius:14px;padding:2rem 2.5rem;
        background:#121c2e;text-align:center}
  .id{font-size:5rem;line-height:1;font-weight:700;
      color:${p.backend === 'A' ? '#4ea1ff' : '#3ddc97'}}
  dl{display:grid;grid-template-columns:auto auto;gap:.25rem 1.25rem;
     text-align:left;margin:1.5rem 0 0}
  dt{opacity:.6} dd{margin:0}
</style>
<div class="card">
  <div class="id">${p.backend}</div>
  <strong>${p.service}</strong>
  <dl>
    <dt>team</dt><dd>${p.team}</dd>
    <dt>host</dt><dd>${p.host}</dd>
    <dt>port</dt><dd>${p.port}</dd>
  </dl>
</div>`;
