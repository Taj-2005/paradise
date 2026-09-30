#!/usr/bin/env bash
# Full-stack smoke test on ONE laptop — no LAN, no sudo, no /etc/hosts edits.
#
# Why this exists: the four-machine setup has a lot of moving parts, and the
# worst time to discover that nginx.conf has a typo is with four laptops on a
# desk and a camera running. This spins the entire stack up locally —
# two backends + nginx + real TLS — and proves the request path works.
#
#   ./scripts/smoke-local.sh
#
# It does NOT test DNS (that needs a second machine to be meaningful). Name
# resolution is faked with curl --resolve, which maps a hostname to an address
# for that one command only. Everything else is real: real certificate, real
# TLS handshake, real round-robin across two separate processes.
#
# Crucially it uses --cacert, never -k. If this passes, your certificate is
# genuinely trusted and the -k rule will not bite you during evaluation.

source "$(dirname "$0")/lib/common.sh"
load_env

WORK="${TMPDIR:-/tmp}/cn-smoke-$$"
PORT_HTTPS=8443
PORT_A=13001
PORT_B=13002
PIDS=()

cleanup() {
  local code=$?
  info "Cleaning up…"
  [[ -f "$WORK/nginx.pid" ]] && kill "$(cat "$WORK/nginx.pid")" 2>/dev/null || true
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  sleep 0.3
  rm -rf "$WORK"
  exit $code
}
trap cleanup EXIT INT TERM

need_cmd nginx
need_cmd curl
need_cmd node

hdr "Local full-stack smoke test — $TEAM"
info "Workdir: $WORK"
mkdir -p "$WORK"/{conf,logs,certs}

# ── 1. Certificate ──────────────────────────────────────────────────────────
step "1/5  TLS certificate"
if [[ ! -f "$CERT_DIR/$APP_DOMAIN.crt" ]]; then
  info "No certificate yet — generating one."
  FORCE=1 "$REPO_ROOT/infra/mac2-edge/scripts/gen-certs.sh" >/dev/null
fi
CA="$CERT_DIR/rootCA.pem"
[[ -f "$CA" ]] || die "No root CA at $CA. Run infra/mac2-edge/scripts/gen-certs.sh first."
ok "Using $CERT_DIR/$APP_DOMAIN.crt"

# ── 2. Backends ─────────────────────────────────────────────────────────────
step "2/5  Starting both backends"
# Refuse to run against someone else's listener. Without this, a leftover
# backend from a previous run answers the readiness probe and the whole test
# silently measures stale code.
for port in "$PORT_A" "$PORT_B" "$PORT_HTTPS"; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    err "Port $port is already in use:"
    lsof -nP -iTCP:"$port" -sTCP:LISTEN | sed 's/^/      /' >&2
    die "Free it first:  pkill -f 'node src/server.js'  (or kill the pid above)"
  fi
done
(cd "$REPO_ROOT/services/backend" && [[ -d node_modules ]]) \
  || (info "npm install…"; cd "$REPO_ROOT/services/backend" && npm install --silent --no-audit --no-fund)

for spec in "A:$PORT_A" "B:$PORT_B"; do
  id="${spec%%:*}"; port="${spec##*:}"
  # `exec` so this subshell is REPLACED by node — otherwise $! is the
  # subshell's pid and killing it orphans the node process, which then keeps
  # the port bound and silently serves stale code to the next run.
  ( cd "$REPO_ROOT/services/backend" && \
    exec env BACKEND_ID="$id" PORT="$port" HOST=0.0.0.0 \
             CACHE_MAX_AGE="$CACHE_MAX_AGE" TEAM="$TEAM" \
      node src/server.js > "$WORK/logs/backend-$id.log" 2>&1 ) &
  PIDS+=("$!")
done

for i in {1..50}; do
  if curl -sf "http://127.0.0.1:$PORT_A/healthz" >/dev/null 2>&1 \
  && curl -sf "http://127.0.0.1:$PORT_B/healthz" >/dev/null 2>&1; then break; fi
  sleep 0.1
  (( i == 50 )) && { cat "$WORK/logs/"*.log; die "backends did not start"; }
done
ok "Backend A on :$PORT_A, Backend B on :$PORT_B"

# ── 3. nginx ────────────────────────────────────────────────────────────────
step "3/5  Starting nginx with the project config"
# Same structure as the real conf.d/site.conf, pointed at loopback ports.
# If this config is wrong, the real one is wrong too.
cat > "$WORK/conf/nginx.conf" <<NGINX
worker_processes 1;
error_log $WORK/logs/error.log warn;
pid       $WORK/nginx.pid;
events { worker_connections 256; }
http {
    access_log $WORK/logs/access.log;
    upstream backend_pool {
        server 127.0.0.1:$PORT_A max_fails=1 fail_timeout=10s;
        server 127.0.0.1:$PORT_B max_fails=1 fail_timeout=10s;
        keepalive 16;
    }
    server {
        listen $PORT_HTTPS ssl;
        http2 on;
        server_name $APP_DOMAIN $API_DOMAIN;
        ssl_certificate     $CERT_DIR/$APP_DOMAIN.crt;
        ssl_certificate_key $CERT_DIR/$APP_DOMAIN.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        location / {
            proxy_pass http://backend_pool;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host \$host;
            proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_next_upstream error timeout http_502 http_503 http_504;
            add_header X-Upstream-Addr \$upstream_addr always;
        }
    }
}
NGINX

nginx -t -c "$WORK/conf/nginx.conf" -p "$WORK" 2>&1 | sed 's/^/      /'
nginx    -c "$WORK/conf/nginx.conf" -p "$WORK"
sleep 0.8
[[ -f "$WORK/nginx.pid" ]] || { cat "$WORK/logs/error.log"; die "nginx failed to start"; }
ok "nginx listening on :$PORT_HTTPS"

# --resolve maps the name to 127.0.0.1 for this command only — it stands in
# for the DNS server we cannot run meaningfully on a single machine.
CURL=(curl --resolve "$APP_DOMAIN:$PORT_HTTPS:127.0.0.1" --cacert "$CA")
URL="https://$APP_DOMAIN:$PORT_HTTPS"

# ── 4. The checks ───────────────────────────────────────────────────────────
step "4/5  Checks"

V="$("${CURL[@]}" -sv "$URL/api/status" 2>&1)"
check_icontains "TLS handshake completes"            "$V" "SSL connection using"
check_icontains "certificate verified WITHOUT -k"    "$V" "SSL certificate verify ok"
check_icontains "SNI/CN matches the domain"          "$V" "$APP_DOMAIN"
check_icontains "HTTP 200 through the proxy"         "$V" "200"
check_not_contains "no TLS verification bypass"     "$V" "server certificate verification SKIPPED"

H="$("${CURL[@]}" -sI "$URL/api/status")"
check_icontains "Cache-Control present (Task F)"     "$H" "max-age=$CACHE_MAX_AGE"
check_icontains "ETag present (Task F)"              "$H" "ETag"
check_icontains "X-Backend passes through the proxy" "$H" "X-Backend"

# The conditional-request demo runs against /api/cacheable, whose body is
# byte-identical on both backends. /api/status embeds the backend id, so its
# ETag differs per replica and round-robin would make the 304 intermittent.
# See services/backend/src/routes/cacheable.js for the full explanation.
ETAG="$("${CURL[@]}" -sI "$URL/api/cacheable" | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '\r')"
info "ETag: $ETAG"
CODES304=""
for _ in 1 2 3 4; do
  CODES304+="$("${CURL[@]}" -s -o /dev/null -w '%{http_code} ' -H "If-None-Match: $ETAG" "$URL/api/cacheable")"
done
info "Four conditional requests returned: $CODES304"
check_not_contains "304 is stable across BOTH backends" "$CODES304" "200"
check_contains     "conditional request returns 304"    "$CODES304" "304"

# And prove the intermittency we designed around is real, so the docs are honest.
ETAG_S="$("${CURL[@]}" -sI "$URL/api/status" | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '\r')"
MIXED=""
for _ in 1 2 3 4; do
  MIXED+="$("${CURL[@]}" -s -o /dev/null -w '%{http_code} ' -H "If-None-Match: $ETAG_S" "$URL/api/status")"
done
info "Same test on /api/status (per-replica ETag): $MIXED  <- why /api/cacheable exists"

SEEN="$(for _ in 1 2 3 4 5 6; do "${CURL[@]}" -sI "$URL/api/status" \
        | awk -F': ' 'tolower($1)=="x-backend"{printf "%s", $2}'; done | tr -d '\r')"
info "Six requests served by: $SEEN"
check_contains "Backend A answered at least once"   "$SEEN" "A"
check_contains "Backend B answered at least once"   "$SEEN" "B"

# ── 5. Failure demo rehearsal ───────────────────────────────────────────────
step "5/5  Failure rehearsal — killing Backend A"
kill "${PIDS[0]}" 2>/dev/null || true
sleep 1
AFTER="$(for _ in 1 2 3 4; do "${CURL[@]}" -sI "$URL/api/status" \
         | awk -F': ' 'tolower($1)=="x-backend"{printf "%s", $2}'; done | tr -d '\r')"
info "After killing A, served by: $AFTER"
check_contains    "traffic continues through B"     "$AFTER" "B"
check_not_contains "A no longer answers"            "$AFTER" "A"

CODES="$(for _ in 1 2 3 4; do "${CURL[@]}" -s -o /dev/null -w '%{http_code} ' "$URL/api/status"; done)"
check_not_contains "no 502s leaked to the client"   "$CODES" "502"

summary
