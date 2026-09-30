#!/usr/bin/env bash
# Mac 2 — verify the edge is proxying, balancing and terminating TLS correctly.

source "$(dirname "$0")/../../../scripts/lib/common.sh"
load_env

hdr "Edge verification — $TEAM"

step "1. Config validity"
nginx -t 2>&1 | sed 's/^/    /'

step "2. Listening sockets"
sudo lsof -nP -iTCP:"$HTTP_PORT" -iTCP:"$HTTPS_PORT" -sTCP:LISTEN 2>/dev/null \
  | grep -i nginx | sed 's/^/    /' || warn "nginx not listening"

step "3. Backends reachable FROM the edge"
# This is the check that distinguishes "backend is down" from "backend is up
# but bound to loopback". Run it here, on Mac 2, not on the backend itself.
for spec in "A:$BACKEND_A_IP:$BACKEND_A_PORT" "B:$BACKEND_B_IP:$BACKEND_B_PORT"; do
  IFS=: read -r id ip port <<< "$spec"
  if curl -sf --max-time 3 "http://$ip:$port/healthz" >/dev/null 2>&1; then
    ok "Backend $id at $ip:$port responds"
  else
    err "Backend $id at $ip:$port unreachable"
    err "  On Mac with $ip, confirm it is bound to 0.0.0.0 not 127.0.0.1:"
    err "    lsof -nP -iTCP:$port -sTCP:LISTEN"
  fi
done

step "4. Certificate"
CRT="$CERT_DIR/$APP_DOMAIN.crt"
if [[ -f "$CRT" ]]; then
  openssl x509 -in "$CRT" -noout -subject -dates 2>/dev/null | sed 's/^/    /'
  openssl x509 -in "$CRT" -noout -text 2>/dev/null \
    | awk '/Subject Alternative Name/{getline; gsub(/^[ \t]+/,""); print "    SAN: " $0}'
  # Expiry warning: a cert that dies the morning of the demo is a bad surprise.
  if ! openssl x509 -in "$CRT" -noout -checkend 604800 >/dev/null 2>&1; then
    warn "Certificate expires within 7 days — regenerate before the demo."
  fi
else
  err "No certificate at $CRT"
fi

step "5. End-to-end through the proxy (no -k)"
curl -sv --resolve "$APP_DOMAIN:$HTTPS_PORT:127.0.0.1" \
     --cacert "$CERT_DIR/rootCA.pem" \
     "https://$APP_DOMAIN:$HTTPS_PORT/api/status" 2>&1 \
  | grep -E 'SSL connection|subject:|issuer:|^< HTTP|^< x-backend|^< X-Backend' \
  | sed 's/^/    /'

step "6. Load balancing over 6 requests"
"$REPO_ROOT/scripts/lb-check.sh" || true

step "7. Recent access log"
tail -8 "$BREW_PREFIX/var/log/nginx/$TEAM-access.log" 2>/dev/null | sed 's/^/    /' \
  || warn "No access log yet"
echo
