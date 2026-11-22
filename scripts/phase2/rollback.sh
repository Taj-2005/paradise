#!/usr/bin/env bash
# [any]  Undo Phase 2 on THIS machine, returning it to its exact Phase 1 state.
#
#   ./rollback.sh                 # = all: everything that applies to this Mac
#   ./rollback.sh primary-dns     # Mac 1     : re-install the Phase 1 dnsmasq config
#   ./rollback.sh cutover         # DNS Macs  : records back to Mac 2 (stays Phase 2)
#   ./rollback.sh backup-dns      # Mac 3     : stop backup dnsmasq, restore old config
#   ./rollback.sh client-dns      # clients   : resolver list back to pre-Phase-2
#   ./rollback.sh isolation       # Mac 3 / 4 : flush pf anchor, release pf token
#   ./rollback.sh standby-edge    # Mac 4     : stop standby nginx, restore old config
#   ./rollback.sh faults          # any       : undo every practice fault injected here
#
# Every step is idempotent: running it twice, or on a Mac where that piece was
# never installed, is a harmless no-op.

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

WHAT="${1:-all}"
DST="$(DNSMASQ_DST)"

rb_cutover() {
  if is_primary_dns || is_backup_dns; then
    if [[ "$(edge_target_ip)" != "$EDGE_IP" ]]; then
      "$P2_SCRIPTS/dns-cutover.sh" primary
    else ok "records already point at Mac 2"; fi
  else info "cutover: not a DNS machine — nothing to do"; fi
}

rb_primary_dns() {
  is_primary_dns || { info "primary-dns: not Mac 1 — nothing to do"; return 0; }
  step "Primary DNS -> exact Phase 1 config"
  # Re-run the Phase 1 installer itself: the most faithful rollback there is.
  "$REPO_ROOT/scripts/render-configs.sh" >/dev/null
  "$REPO_ROOT/infra/mac1-dns/install.sh"
  sudo rm -f "$DST.pre-phase2"
  rm -f "$P2_STATE/edge-target"
  ok "Mac 1 is back on Phase 1 dnsmasq (TTL $DNS_TTL)"
}

rb_backup_dns() {
  is_backup_dns || { info "backup-dns: not the backup DNS machine — nothing to do"; return 0; }
  step "Backup DNS -> stopped, config restored"
  dnsmasq_stop
  if [[ -f "$DST.pre-phase2" ]]; then
    sudo mv "$DST.pre-phase2" "$DST"; ok "restored $DST from pre-phase2 copy"
  fi
  rm -f "$P2_STATE/edge-target"
  dnsmasq_running && warn "a dnsmasq is still running" || ok "dnsmasq stopped on $(my_ip)"
}

rb_client_dns() {
  local f="$P2_STATE/client-dns-before-phase2.txt"
  [[ -f "$f" ]] || { info "client-dns: no Phase 2 change recorded — nothing to do"; return 0; }
  step "Client resolvers -> pre-Phase-2 setting"
  local servers=() l
  while IFS= read -r l; do [[ -n "$l" ]] && servers+=("$l"); done < "$f"
  [[ ${#servers[@]} -gt 0 ]] || servers=(Empty)
  sudo networksetup -setdnsservers "$NET_SERVICE" "${servers[@]}"
  flush_client_dns; rm -f "$f"
  ok "resolvers: $(networksetup -getdnsservers "$NET_SERVICE" | tr '\n' ' ')"
}

rb_isolation() {
  step "pf isolation -> removed"
  sudo pfctl -a "$PF_ANCHOR" -F all 2>/dev/null || true
  ok "anchor $PF_ANCHOR flushed"
  if [[ -s "$P2_STATE/pf-tokens" ]]; then
    while IFS= read -r t; do [[ -n "$t" ]] && sudo pfctl -X "$t" 2>/dev/null || true; done < "$P2_STATE/pf-tokens"
    rm -f "$P2_STATE/pf-tokens"; ok "released our pf enable token(s)"
  fi
  if [[ -f "$P2_STATE/pf-backup-latest/status.txt" ]]; then
    info "pf before Phase 2: $(cat "$P2_STATE/pf-backup-latest/status.txt")   now: $(sudo pfctl -s info 2>/dev/null | head -1)"
  fi
}

rb_standby_edge() {
  is_standby_edge || { info "standby-edge: not the standby machine — nothing to do"; return 0; }
  local NGX_ETC="$BREW_PREFIX/etc/nginx" SUDO=""; (( HTTPS_PORT < 1024 )) && SUDO="sudo"
  [[ -f "$P2_STATE/standby-site-installed" ]] || { info "standby-edge: never installed — nothing to do"; return 0; }
  step "Standby edge -> stopped, config restored"
  $SUDO nginx -s stop 2>/dev/null || true
  [[ -f "$NGX_ETC/nginx.conf.pre-phase2" ]] && mv "$NGX_ETC/nginx.conf.pre-phase2" "$NGX_ETC/nginx.conf"
  if [[ -f "$NGX_ETC/conf.d/site.conf.pre-phase2" ]]; then mv "$NGX_ETC/conf.d/site.conf.pre-phase2" "$NGX_ETC/conf.d/site.conf"
  else rm -f "$NGX_ETC/conf.d/site.conf"; fi
  if [[ -f "$P2_STATE/standby-moved-default-server" && -f "$NGX_ETC/servers/default.disabled" ]]; then
    mv "$NGX_ETC/servers/default.disabled" "$NGX_ETC/servers/default"; rm -f "$P2_STATE/standby-moved-default-server"
  fi
  rm -f "$P2_STATE/standby-site-installed"
  ok "standby nginx stopped and its config restored"
}

rb_faults() {
  local f any=0
  for f in "$P2_STATE"/fault-*; do
    [[ -e "$f" ]] || continue
    case "$(basename "$f")" in fault-pf.conf|fault-pf-token) continue ;; esac
    any=1; "$P2_SCRIPTS/inject-fault.sh" "${f##*/fault-}" undo || true
  done
  (( any )) || info "faults: none injected here"
}

hdr "Phase 2 rollback on $(my_ip) ($(my_role)) — $WHAT"
case "$WHAT" in
  cutover)      rb_cutover ;;
  primary-dns)  rb_primary_dns ;;
  backup-dns)   rb_backup_dns ;;
  client-dns)   rb_client_dns ;;
  isolation)    rb_isolation ;;
  standby-edge) rb_standby_edge ;;
  faults)       rb_faults ;;
  all)
    confirm "Undo ALL Phase 2 changes on this machine" || exit 0
    rb_faults; rb_client_dns; rb_isolation; rb_standby_edge; rb_backup_dns; rb_primary_dns ;;
  *) die "Unknown component '$WHAT'. See the header of $(basename "$0")." ;;
esac
echo; ok "Rollback '$WHAT' complete."
