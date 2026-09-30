import { config } from '../config.js';

// Task C + Task D evidence: every single response carries X-Backend: A|B.
// This is what makes round-robin load balancing *visible* — without it you
// cannot prove which of the two upstreams served a given request.
//
// Set via res.setHeader before anything is written, so it is present on JSON
// responses, 304 Not Modified responses and error responses alike.
export function backendHeader(req, res, next) {
  res.setHeader('X-Backend', config.backendId);
  res.setHeader('X-Backend-Port', String(config.port));
  res.setHeader('X-Backend-Host', config.hostname);
  next();
}
