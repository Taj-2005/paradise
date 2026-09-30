#!/usr/bin/env bash
# Mac 2 — install and start the edge reverse proxy + load balancer.
# Spec Tasks D and E. Safe to re-run.

source "$(dirname "$0")/../../../scripts/lib/common.sh"
load_env
require_role mac2-edge

NGX_ETC="$BREW_PREFIX/etc/nginx"
hdr "Mac 2 — edge (nginx) for $TEAM"

# ── 1. Install nginx ────────────────────────────────────────────────────────
if ! command -v nginx >/dev/null 2>&1; then
  info "Installing nginx via Homebrew…"
  need_cmd brew
  brew install nginx
else
  ok "nginx already installed ($(nginx -v 2>&1))"
fi

# ── 2. Certificate ──────────────────────────────────────────────────────────
if [[ ! -f "$CERT_DIR/$APP_DOMAIN.crt" ]]; then
  info "No certificate yet — generating."
  "$REPO_ROOT/infra/mac2-edge/scripts/gen-certs.sh"
else
  ok "Certificate present: $CERT_DIR/$APP_DOMAIN.crt"
fi

# ── 3. Render + install configs ─────────────────────────────────────────────
"$REPO_ROOT/scripts/render-configs.sh" >/dev/null
ok "Configs rendered from .env"

mkdir -p "$NGX_ETC/conf.d" "$BREW_PREFIX/var/log/nginx" "$BREW_PREFIX/var/run"

# One pristine backup, taken the first time only.
if [[ -f "$NGX_ETC/nginx.conf" && ! -f "$NGX_ETC/nginx.conf.orig" ]]; then
  cp "$NGX_ETC/nginx.conf" "$NGX_ETC/nginx.conf.orig"
  ok "Backed up stock config -> nginx.conf.orig"
fi

cp "$REPO_ROOT/infra/mac2-edge/nginx/nginx.conf"          "$NGX_ETC/nginx.conf"
cp "$REPO_ROOT/infra/mac2-edge/nginx/conf.d/site.conf"    "$NGX_ETC/conf.d/site.conf"
ok "Installed nginx.conf + conf.d/site.conf"

# Homebrew ships a default server on :8080 that collides with ours if you
# chose the unprivileged port pair. Move it out of the way.
if [[ -f "$NGX_ETC/servers/default" ]]; then
  mv "$NGX_ETC/servers/default" "$NGX_ETC/servers/default.disabled"
  ok "Disabled Homebrew's default server block"
fi

# ── 4. Validate before (re)starting ─────────────────────────────────────────
info "Validating configuration…"
if ! nginx -t 2>&1 | sed 's/^/      /'; then
  die "nginx -t failed — fix the template, re-render, and retry."
fi
ok "Configuration valid"

# ── 5. Privileged-port warning ──────────────────────────────────────────────
# Binding below 1024 requires root. If HTTPS_PORT is 443 nginx must run under
# sudo; the spec allows 8443 instead with no penalty.
SUDO=""
if (( HTTPS_PORT < 1024 )); then
  warn "Port $HTTPS_PORT is privileged — nginx must run as root."
  warn "If this is a problem, set HTTPS_PORT=8443 HTTP_PORT=8080 in .env"
  warn "and re-run. The spec allows it with no marks deducted."
  SUDO="sudo"
fi

# ── 6. Start / reload ───────────────────────────────────────────────────────
if $SUDO nginx -s reload 2>/dev/null; then
  ok "Reloaded running nginx"
else
  info "Starting nginx…"
  $SUDO nginx
fi
sleep 1

# ── 7. Prove it ─────────────────────────────────────────────────────────────
step "Self-test"
if $SUDO lsof -nP -iTCP:"$HTTPS_PORT" -sTCP:LISTEN 2>/dev/null | grep -q nginx; then
  ok "nginx listening on :$HTTPS_PORT"
else
  err "Nothing listening on :$HTTPS_PORT — check $BREW_PREFIX/var/log/nginx/error.log"
  exit 1
fi

# --resolve so this works even before the client's DNS is pointed at Mac 1.
CODE="$(curl -s -o /dev/null -w '%{http_code}' \
  --resolve "$APP_DOMAIN:$HTTPS_PORT:127.0.0.1" \
  --cacert "$CERT_DIR/rootCA.pem" \
  "https://$APP_DOMAIN:$HTTPS_PORT/api/status" 2>/dev/null || echo 000)"

case "$CODE" in
  200) ok "End-to-end 200 through the proxy (TLS verified, no -k)" ;;
  502) err "502 Bad Gateway — nginx is up but cannot reach the backends."
       err "Check that Mac 3 and Mac 4 are running and bound to 0.0.0.0."
       err "  curl http://$BACKEND_A_IP:$BACKEND_A_PORT/healthz"
       err "  curl http://$BACKEND_B_IP:$BACKEND_B_PORT/healthz" ;;
  000) err "Connection failed entirely. Is the certificate readable by nginx?" ;;
  *)   warn "Unexpected status $CODE" ;;
esac

cat <<NEXT

  ${C_BLD}Edge is up.${C_OFF}

  Distribute the CA so no one ever needs -k:
      scp $CERT_DIR/rootCA.pem <each-mac>:~/
      # then on each Mac:  make client-trust

  Watch requests arrive (good for the video):
      tail -f $BREW_PREFIX/var/log/nginx/$TEAM-access.log

  Stop / restore:
      $SUDO nginx -s stop
      cp $NGX_ETC/nginx.conf.orig $NGX_ETC/nginx.conf

NEXT
