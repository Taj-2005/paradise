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
# macOS runs mDNSResponder, and some VPN clients bind 53 too. If something
# else already holds the port, dnsmasq starts and immediately dies, which
# looks identical to "config is wrong" unless you check.
if sudo lsof -nP -iUDP:53 2>/dev/null | grep -v dnsmasq | grep -q LISTEN; then
  warn "Something else is already listening on UDP/53:"
  sudo lsof -nP -iUDP:53 | sed 's/^/      /' >&2
fi

# ── 5. Start as a launchd service so it survives reboots and sleep ──────────
info "Restarting dnsmasq…"
if sudo brew services list 2>/dev/null | grep -q '^dnsmasq.*started'; then
  sudo brew services restart dnsmasq
else
  sudo brew services start dnsmasq
fi

sleep 2

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
