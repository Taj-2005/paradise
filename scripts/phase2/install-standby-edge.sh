#!/usr/bin/env bash
# [Mac 4 · standby edge]  Extension E — a second nginx edge, same configuration.
#
# Renders the Phase 1 nginx.conf.template + site.conf.template with only two
# values changed: EDGE_IP=<this Mac> (so X-Edge / edge-health identify it) and
# CERT_DIR=infra/phase2/certs. Same upstream pool, same TLS policy, same cert —
# so clients cannot tell the edges apart except by the X-Edge header.
#
# The certificate is reused as-is: clients connect by NAME, the cert's SAN
# covers app/api.<team>.test, and the issuing CA is already trusted on every
# Mac from Phase 1. No new CA, no re-trusting.

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env
p2_require_ip "$STANDBY_EDGE_IP" "standby edge"

NGX_ETC="$BREW_PREFIX/etc/nginx"
CRT="$P2_CERT_DIR/$APP_DOMAIN.crt"; KEY="$P2_CERT_DIR/$APP_DOMAIN.key"; CA="$P2_CERT_DIR/rootCA.pem"

hdr "Extension E — standby edge on $(my_ip)"

# 1. nginx
if ! command -v nginx >/dev/null 2>&1; then
  info "Installing nginx via Homebrew…"; need_cmd brew; brew install nginx
else ok "nginx present ($(nginx -v 2>&1))"; fi

# 2. Certificate copied from Mac 2
missing=0
for f in "$CRT" "$KEY" "$CA"; do [[ -f "$f" ]] || { err "missing ${f#"$REPO_ROOT"/}"; missing=1; }; done
if (( missing )); then
  cat >&2 <<COPY

  Copy the edge certificate from Mac 2 ($EDGE_IP). On Mac 2, in the repo:
      scp infra/mac2-edge/certs/$APP_DOMAIN.crt \\
          infra/mac2-edge/certs/$APP_DOMAIN.key \\
          infra/mac2-edge/certs/rootCA.pem \\
          <user>@$STANDBY_EDGE_IP:<repo>/infra/phase2/certs/
  Then re-run:  make p2-standby-edge

  (infra/phase2/certs/ is gitignored — the private key never reaches git.)
COPY
  exit 1
fi
chmod 600 "$KEY"
openssl x509 -in "$CRT" -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name' | grep -q "DNS:$APP_DOMAIN" \
  && ok "Certificate SAN covers $APP_DOMAIN" || die "Certificate SAN does not cover $APP_DOMAIN"
[[ "$(openssl x509 -in "$CRT" -noout -pubkey | openssl sha256)" == "$(openssl pkey -in "$KEY" -pubout | openssl sha256)" ]] \
  && ok "Key and certificate match" || die "Key does not match certificate"

# 3. Render + install (with rollback copies)
render_standby_edge
mkdir -p "$NGX_ETC/conf.d" "$BREW_PREFIX/var/log/nginx" "$BREW_PREFIX/var/run"
if [[ -f "$NGX_ETC/nginx.conf" && ! -f "$NGX_ETC/nginx.conf.pre-phase2" ]]; then
  cp "$NGX_ETC/nginx.conf" "$NGX_ETC/nginx.conf.pre-phase2"; ok "Rollback copy -> nginx.conf.pre-phase2"
fi
if [[ ! -f "$P2_STATE/standby-site-installed" ]]; then
  if [[ -f "$NGX_ETC/conf.d/site.conf" ]]; then cp "$NGX_ETC/conf.d/site.conf" "$NGX_ETC/conf.d/site.conf.pre-phase2"; fi
  touch "$P2_STATE/standby-site-installed"
fi
cp "$P2_STANDBY_NGX_CONF"  "$NGX_ETC/nginx.conf"
cp "$P2_STANDBY_SITE_CONF" "$NGX_ETC/conf.d/site.conf"
ok "Installed nginx.conf + conf.d/site.conf"
if [[ -f "$NGX_ETC/servers/default" ]]; then
  mv "$NGX_ETC/servers/default" "$NGX_ETC/servers/default.disabled"
  touch "$P2_STATE/standby-moved-default-server"
  ok "Disabled Homebrew's default server block"
fi

SUDO=""; (( HTTPS_PORT < 1024 )) && SUDO="sudo"
info "Validating…"
$SUDO nginx -t 2>&1 | sed 's/^/      /' || die "nginx -t failed"
ok "Configuration valid"

# 4. Start
if $SUDO nginx -s reload 2>/dev/null; then ok "Reloaded running nginx"; else info "Starting nginx…"; $SUDO nginx; fi
sleep 1

# 5. Prove it — by name, verified TLS, no -k
step "Self-test"
raw="$(curl -s -D - -o /dev/null --resolve "$APP_DOMAIN:$HTTPS_PORT:127.0.0.1" --cacert "$CA" \
        "https://$APP_DOMAIN:$HTTPS_PORT/api/status" 2>/dev/null || true)"
code="$(printf '%s' "$raw" | awk 'NR==1{print $2}')"
edge="$(printf '%s' "$raw" | awk -F': ' 'tolower($1)=="x-edge"{gsub(/\r/,"");print $2}')"
[[ "$code" == 200 ]] && ok "200 through the standby (TLS verified, no -k)" || err "HTTP ${code:-000} — check the backends and pf allow-list"
[[ "$edge" == *"$STANDBY_EDGE_IP"* ]] && ok "X-Edge: $edge" || warn "X-Edge: '${edge}' (expected nginx@$STANDBY_EDGE_IP)"

cat <<NEXT

  ${C_BLD}Standby edge is up — but no client uses it yet.${C_OFF} DNS still points at Mac 2.
  Cut over (Ext E), on Mac 1 AND on the backup DNS:
      make p2-cutover TO=standby
  while a client runs:
      make p2-ttl-watch
  Roll back:
      make p2-rollback WHAT=standby-edge

NEXT
