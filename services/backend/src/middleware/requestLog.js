import { config } from '../config.js';

// A deliberately loud one-line access log. During the video demo this terminal
// is on screen: when a request lands you SEE which backend took it, including
// the client's ephemeral source port — the same port you point at in Wireshark.
export function requestLog(req, res, next) {
  const started = process.hrtime.bigint();

  res.on('finish', () => {
    const ms = Number(process.hrtime.bigint() - started) / 1e6;
    const ts = new Date().toISOString().slice(11, 23);

    // req.socket.remotePort is the client's EPHEMERAL source port. When nginx
    // is proxying, the "client" here is nginx on Mac 2 — proof that backends
    // are never contacted directly. X-Forwarded-For carries the real origin.
    const peer = `${req.socket.remoteAddress}:${req.socket.remotePort}`;
    const xff = req.headers['x-forwarded-for'] ?? '-';

    console.log(
      `${ts}  [${config.backendId}]  ${req.method} ${req.originalUrl}  ` +
      `${res.statusCode}  ${ms.toFixed(1)}ms  from=${peer}  xff=${xff}`
    );
  });

  next();
}
