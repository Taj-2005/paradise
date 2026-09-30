#!/usr/bin/env bash
# Mac 4 — run Backend B.
#
# There is no code specific to this machine. The same service in
# services/backend/ becomes Backend B purely through the environment set
# below, which is read from .env so the port lives in exactly one place.

source "$(dirname "$0")/../../scripts/lib/common.sh"
load_env
require_role mac4-backend-b

cd "$REPO_ROOT/services/backend"

if [[ ! -d node_modules ]]; then
  info "Installing dependencies…"
  need_cmd npm node
  npm install --no-audit --no-fund
fi

PORT_VAL="$BACKEND_B_PORT"

hdr "Backend B — port $PORT_VAL"
info "Bound to 0.0.0.0 so nginx on $EDGE_IP can reach it."
info "Ctrl-C to stop (this is the failure demo for spec 6.3 Option A)."
echo

exec env \
  BACKEND_ID=B \
  PORT="$PORT_VAL" \
  HOST=0.0.0.0 \
  CACHE_MAX_AGE="$CACHE_MAX_AGE" \
  TEAM="$TEAM" \
  node src/server.js
