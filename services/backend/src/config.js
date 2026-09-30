// All runtime configuration comes from the environment so that ONE codebase
// can be Backend A on Mac 3 and Backend B on Mac 4 with no code difference.
// Mac 3:  BACKEND_ID=A PORT=3001
// Mac 4:  BACKEND_ID=B PORT=3002

import os from 'node:os';

const required = (name, fallback) => {
  const v = process.env[name] ?? fallback;
  if (v === undefined) {
    console.error(`FATAL: environment variable ${name} is required`);
    process.exit(1);
  }
  return v;
};

export const config = {
  backendId: required('BACKEND_ID'),
  port: Number(required('PORT')),

  // ── The single most common way this project breaks ──────────────────────
  // Binding to 127.0.0.1 makes the service reachable ONLY from this laptop.
  // nginx on Mac 2 would then get ECONNREFUSED and every request 502s.
  // Spec §6 Task C: "Backends must listen on a LAN-accessible interface —
  // do NOT bind to 127.0.0.1 only". 0.0.0.0 means "every interface".
  host: required('HOST', '0.0.0.0'),

  // Task F: the Cache-Control max-age advertised on cacheable endpoints.
  cacheMaxAge: Number(required('CACHE_MAX_AGE', '60')),

  team: required('TEAM', 'paradise'),
  hostname: os.hostname(),
  startedAt: new Date().toISOString(),
};

if (config.host === '127.0.0.1' || config.host === 'localhost') {
  console.error('');
  console.error('  REFUSING TO START: HOST is set to loopback.');
  console.error('  nginx on the edge machine will not be able to reach this');
  console.error('  backend, and every request through the load balancer will');
  console.error('  return 502 Bad Gateway. Set HOST=0.0.0.0 instead.');
  console.error('');
  process.exit(1);
}
