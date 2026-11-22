#!/usr/bin/env bash
# [Mac 3 · backup DNS]  Extension A — a second, independent resolver.
#
# Same Phase 1 dnsmasq template, same records, rendered for this machine.
# Independent on purpose: it does NOT forward .test queries to Mac 1, because a
# backup that depends on the primary fails together with it.
# (Production equivalent: secondary name servers kept in sync by zone transfer,
#  or Route 53's four name servers per hosted zone.)

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env
p2_require_ip "$BACKUP_DNS_IP" "backup DNS machine"

hdr "Extension A — backup DNS on $(my_ip)"

# 1. Install
if ! command -v dnsmasq >/dev/null 2>&1; then
  info "Installing dnsmasq via Homebrew…"; need_cmd brew; brew install dnsmasq
else
  ok "dnsmasq present ($(dnsmasq --version | head -1))"
fi

# 2. Port 53 must be free (or already ours)
port53_free_or_dnsmasq || exit 1
ok "Port 53 is available"

# 3. Render + install + start
TARGET="$(edge_target_ip)"
render_dns_profile backup "$TARGET"
dnsmasq_install_conf "$P2_BACKUP_DNS_CONF"
dnsmasq_restart

# 4. Self-test
step "Self-test"
got="$(dig_a 127.0.0.1 "$APP_DOMAIN")"
[[ "$got" == "$TARGET" ]] && ok "$APP_DOMAIN -> $got (via 127.0.0.1)" \
  || die "Local answer '$got', expected $TARGET"
got="$(dig_a "$BACKUP_DNS_IP" "$API_DOMAIN")"
[[ "$got" == "$TARGET" ]] && ok "$API_DOMAIN -> $got (via $BACKUP_DNS_IP — reachable from the LAN)" \
  || die "LAN answer '$got' — check interface/listen-address in the rendered config"
ttl="$(dig_ttl "$BACKUP_DNS_IP" "$APP_DOMAIN")"
[[ "$ttl" == "$P2_DNS_TTL" ]] && ok "TTL = ${ttl}s" || warn "TTL = '${ttl}' (expected $P2_DNS_TTL)"

prim="$(dig_a "$DNS_IP" "$APP_DOMAIN")"
if [[ -z "$prim" ]]; then
  warn "Primary ($DNS_IP) did not answer — fine if it is stopped on purpose."
elif [[ "$prim" == "$TARGET" ]]; then
  ok "Primary and backup agree: $APP_DOMAIN -> $prim"
else
  warn "Primary says $prim, backup says $TARGET — records out of sync!"
  warn "Run 'make p2-cutover TO=…' on both DNS machines with the same target."
fi

cat <<NEXT

  ${C_BLD}Backup DNS is up.${C_OFF}
  Next, on every client (Mac 1, Mac 3, Mac 4):
      make p2-client-dns        # resolvers = $DNS_IP (primary), $BACKUP_DNS_IP (backup)
  Watch queries arrive here:
      sudo tail -f $BREW_PREFIX/var/log/dnsmasq.log
  Roll back:
      make p2-rollback WHAT=backup-dns

NEXT
