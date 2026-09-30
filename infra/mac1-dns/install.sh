#!/usr/bin/env bash
# Mac 1 — install and start the private DNS server (spec Task B).
# Safe to re-run: it reinstalls the config and restarts the service.

source "$(dirname "$0")/../../scripts/lib/common.sh"
load_env
require_role mac1-dns

CONF_SRC="$REPO_ROOT/infra/mac1-dns/dnsmasq.conf"
CONF_DST="$BREW_PREFIX/etc/dnsmasq.conf"
LOG="$BREW_PREFIX/var/log/dnsmasq.log"

hdr "Mac 1 — private DNS (dnsmasq) for $TEAM"

# ── 1. Install ──────────────────────────────────────────────────────────────
if ! command -v dnsmasq >/dev/null 2>&1; then
  info "Installing dnsmasq via Homebrew…"
  need_cmd brew
  brew install dnsmasq
else
  ok "dnsmasq already installed ($(dnsmasq --version | head -1))"
fi

# ── 2. Render + back up + install the config ────────────────────────────────
[[ -f "$CONF_SRC" ]] || { info "Rendering config…"; "$REPO_ROOT/scripts/render-configs.sh" >/dev/null; }

if [[ -f "$CONF_DST" && ! -f "$CONF_DST.orig" ]]; then
  # Keep exactly one pristine backup, taken the first time we ever ran.
  sudo cp "$CONF_DST" "$CONF_DST.orig"
  ok "Backed up original config -> $CONF_DST.orig"
fi

sudo cp "$CONF_SRC" "$CONF_DST"
ok "Installed $CONF_DST"

sudo mkdir -p "$(dirname "$LOG")"
sudo touch "$LOG"
sudo chmod 644 "$LOG"

# ── 3. Validate BEFORE restarting, so a typo cannot take DNS down ───────────
info "Validating configuration…"
if sudo dnsmasq --test --conf-file="$CONF_DST" 2>&1 | grep -q "syntax check OK"; then
  ok "Config syntax OK"
else
  err "Config failed dnsmasq --test:"
  sudo dnsmasq --test --conf-file="$CONF_DST" 2>&1 | sed 's/^/      /' >&2
  exit 1
fi

# The one mistake that silently breaks the whole team.
if grep -qE '^\s*listen-address\s*=\s*127\.0\.0\.1' "$CONF_DST"; then
  die "listen-address is 127.0.0.1 — no other Mac will be able to resolve. Fix the template."
fi
ok "listen-address is not loopback"

# ── 4. Port 53 conflict check ───────────────────────────────────────────────
# macOS runs mDNSResponder, and VPN / zero-trust agents (Zscaler, WARP, Cisco)
# bind 53 too. If something else already holds the port, dnsmasq fails to
# create its listening socket and dies, which looks identical to "the config is
# wrong" unless you check.
#
# Note: do NOT filter on "LISTEN" here. That state only appears for TCP, so a
# UDP-only occupant — the normal case for DNS — slips straight through.
CONFLICT="$(sudo lsof -nP -iUDP:53 -iTCP:53 2>/dev/null | awk 'NR>1 && $1 != "dnsmasq"')"
if [[ -n "$CONFLICT" ]]; then
  err "Port 53 is already in use by another process:"
  printf '%s\n' "$CONFLICT" | sed 's/^/      /' >&2
  echo >&2
  err "dnsmasq cannot bind while that holds the port. Usual causes:"
  err "  mDNSResponder  — turn off System Settings > General > Sharing >"
  err "                   Internet Sharing, which makes macOS run a DNS proxy"
  err "  a VPN / zero-trust agent (Zscaler, Cloudflare WARP, Cisco Secure"
  err "                   Client, Tailscale) — quit it for the demonstration"
  echo >&2
  err "Clients set their resolver by IP only, with no port, so the service has"
  err "to be on 53. If you cannot free it on this Mac, run the DNS role on a"
  err "different machine and update DNS_IP in .env."
  exit 1
fi
ok "Port 53 is free"

# ── 5. Start as a launchd service so it survives reboots and sleep ──────────
# `brew services start` can fail with "Bootstrap failed: 5: Input/output error".
# That is launchd's EIO, and it means launchd still holds a registration for
# sh.brew.dnsmasq from an earlier attempt — even when no dnsmasq is running.
# Booting the label out first clears it. If launchd still refuses, we fall back
# to running dnsmasq directly, which is all the demo actually needs.
start_dnsmasq() {
  if sudo brew services list 2>/dev/null | grep -q '^dnsmasq.*started'; then
    sudo brew services restart dnsmasq 2>&1 && return 0
  else
    sudo brew services start dnsmasq 2>&1 && return 0
  fi
  return 1
}

info "Starting dnsmasq…"
if ! start_dnsmasq >/dev/null 2>&1; then
  warn "launchd refused the service — clearing a stale registration and retrying."
  sudo launchctl bootout system/sh.brew.dnsmasq 2>/dev/null || true
  sleep 1
  if ! start_dnsmasq >/dev/null 2>&1; then
    warn "brew services still will not start it. Running dnsmasq directly instead."
    warn "This does not survive a reboot — re-run 'make dns' if the Mac restarts."
    sudo pkill -x dnsmasq 2>/dev/null || true
    sleep 1
    sudo dnsmasq --conf-file="$CONF_DST"
  fi
fi

sleep 2

# Whatever route we took, something must now be listening on 53.
if ! sudo lsof -nP -iUDP:53 2>/dev/null | grep -q dnsmasq; then
  err "dnsmasq is still not listening on UDP/53."
  err "Check the log:  tail -20 $LOG"
  err "Try by hand:    sudo dnsmasq --conf-file=$CONF_DST --no-daemon"
  exit 1
fi
ok "dnsmasq is listening on UDP/53"

# ── 6. Prove it works from this machine ─────────────────────────────────────
step "Self-test"
if dig +short +time=2 +tries=1 "@127.0.0.1" "$APP_DOMAIN" | grep -q "^$EDGE_IP$"; then
  ok "$APP_DOMAIN -> $EDGE_IP (via 127.0.0.1)"
else
  err "Local resolution failed. Check: sudo brew services list; tail $LOG"
  exit 1
fi

if dig +short +time=2 +tries=1 "@$DNS_IP" "$API_DOMAIN" | grep -q "^$EDGE_IP$"; then
  ok "$API_DOMAIN -> $EDGE_IP (via $DNS_IP — reachable from the LAN)"
else
  err "Resolution via the LAN address $DNS_IP failed."
  err "Queries work on loopback but not on the interface — check listen-address/interface."
  exit 1
fi

cat <<NEXT

  ${C_BLD}DNS is up.${C_OFF}

  Next, on Mac 2, Mac 3 and Mac 4:
      make client-dns          # point their resolver at $DNS_IP

  Watch queries arrive live (great for the video):
      sudo tail -f $LOG

  Stop / restore:
      sudo brew services stop dnsmasq

NEXT
