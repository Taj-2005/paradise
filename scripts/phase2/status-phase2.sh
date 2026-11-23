#!/usr/bin/env bash
# [any]  What Phase 2 state is THIS machine in? Read-only.

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

roles="$(my_role)"
is_backup_dns   && roles="$roles + backup-dns"
is_standby_edge && roles="$roles + standby-edge"
hdr "Phase 2 status — $(my_ip) ($roles)"

step "DNS service"
if dnsmasq_running; then
  ok "dnsmasq running"
  c="$(DNSMASQ_DST)"
  if grep -q 'PHASE 2 PROFILE' "$c" 2>/dev/null; then
    info "installed profile: $(grep -m1 'PHASE 2 PROFILE' "$c" | sed 's/.*PROFILE: //')"
  else info "installed profile: Phase 1 ($(grep -m1 '^local-ttl' "$c" 2>/dev/null || echo 'no local-ttl'))"; fi
else info "dnsmasq not running here"; fi
info "edge target recorded here: $(edge_target_ip) ($(edge_label "$(edge_target_ip)"))"

step "Client resolvers"
info "$NET_SERVICE: $(networksetup -getdnsservers "$NET_SERVICE" 2>/dev/null | tr '\n' ' ')"
info "OS resolves $APP_DOMAIN -> $(os_cache_ip "$APP_DOMAIN")"

step "pf"
info "$(sudo -n pfctl -s info 2>/dev/null | head -1 || echo 'pf status needs sudo — run sudo -v first')"
r="$(sudo -n pfctl -a "$PF_ANCHOR" -sr 2>/dev/null || true)"
[[ -n "$r" ]] && { ok "isolation anchor active:"; printf '%s\n' "$r" | sed 's/^/      /'; } || info "isolation anchor empty"

step "nginx"
if pgrep -x nginx >/dev/null; then
  ok "nginx running"
  is_standby_edge && info "this is the STANDBY edge"
  is_edge && info "this is the PRIMARY edge"
else info "nginx not running here"; fi

step "Practice faults active here"
ls "$P2_STATE"/fault-* 2>/dev/null | grep -vE 'fault-pf' | sed 's|.*/fault-|      |' || info "none"
