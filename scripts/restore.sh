#!/usr/bin/env bash
# Return THIS machine to the known-good Phase 1 state.
# Idempotent — safe to run at any time, including when nothing is broken.
#
# Run this after any failure demo, and before recording the video.

source "$(dirname "$0")/lib/common.sh"
load_env

ROLE="$(my_role)"
hdr "Restore — $(hostname -s) (role: $ROLE)"

# ── DNS client setting (any machine) ────────────────────────────────────────
step "Client resolver"
current="$(networksetup -getdnsservers "$NET_SERVICE" 2>/dev/null | head -1)"
if [[ "$current" == "$DNS_IP" ]]; then
  ok "already pointed at Mac 1 ($DNS_IP)"
else
  info "currently '$current' — repointing at $DNS_IP"
  sudo networksetup -setdnsservers "$NET_SERVICE" "$DNS_IP"
  sudo dscacheutil -flushcache
  sudo killall -HUP mDNSResponder 2>/dev/null || true
  ok "repointed"
fi

# ── Per-role services ───────────────────────────────────────────────────────
case "$ROLE" in
  mac1-dns)
    step "dnsmasq"
    if sudo brew services list 2>/dev/null | grep -q '^dnsmasq.*started'; then
      ok "running"
    else
      info "starting…"; sudo brew services start dnsmasq; sleep 2
    fi
    dig +short "@127.0.0.1" "$APP_DOMAIN" | grep -q "$EDGE_IP" \
      && ok "resolving correctly" || err "not resolving — run ./infra/mac1-dns/install.sh"
    ;;

  mac2-edge)
    step "nginx"
    SUDO=""; (( HTTPS_PORT < 1024 )) && SUDO="sudo"
    if $SUDO lsof -nP -iTCP:"$HTTPS_PORT" -sTCP:LISTEN 2>/dev/null | grep -q nginx; then
      info "running — reloading config"
      $SUDO nginx -s reload && ok "reloaded"
    else
      info "starting…"
      nginx -t && $SUDO nginx && ok "started"
    fi
    ;;

  mac3-backend-a|mac4-backend-b)
    if [[ "$ROLE" == mac3-backend-a ]]; then id=A; port="$BACKEND_A_PORT"; else id=B; port="$BACKEND_B_PORT"; fi
    step "Backend $id"
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      ok "listening on :$port"
    else
      warn "not running. Start it in its own terminal so you can see the log:"
      warn "    make backend-$(printf '%s' "$id" | tr 'A-Z' 'a-z')"
    fi
    ;;

  *)
    warn "Unrecognised machine (IP $(my_ip) is not in .env)."
    warn "Update DNS_IP / EDGE_IP / BACKEND_A_IP / BACKEND_B_IP and re-run."
    ;;
esac

# ── End-to-end ──────────────────────────────────────────────────────────────
step "End-to-end check"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$APP_URL/api/status" 2>/dev/null || echo 000)"
case "$code" in
  200) ok "$APP_URL/api/status -> 200. System is up." ;;
  502) err "502 — the edge is up but no backend is reachable. Start Mac 3 and Mac 4." ;;
  000) err "No connection. Check: ./scripts/status.sh" ;;
  *)   warn "HTTP $code" ;;
esac
echo
