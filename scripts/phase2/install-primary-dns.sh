#!/usr/bin/env bash
# [Mac 1 · primary DNS]  Extension B — re-install the primary with a visible TTL.
#
# Phase 1 runs with local-ttl=0 (no client caching, deterministic demos).
# Phase 2 needs caching to be OBSERVABLE, so this installs the Phase 2 profile:
# the identical Phase 1 template with DNS_TTL=${P2_DNS_TTL}. The Phase 1 config
# is saved first and `make p2-rollback WHAT=primary-dns` puts it back.

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env
p2_require_ip "$DNS_IP" "primary DNS (Mac 1)"

hdr "Extension B — primary DNS with TTL ${P2_DNS_TTL}s"

TARGET="$(edge_target_ip)"
render_dns_profile primary "$TARGET"
dnsmasq_install_conf "$P2_PRIMARY_DNS_CONF"
dnsmasq_restart

step "Self-test"
got="$(dig_a "$DNS_IP" "$APP_DOMAIN")"
[[ "$got" == "$TARGET" ]] && ok "$APP_DOMAIN -> $got" || die "Answer '$got', expected $TARGET"
ttl="$(dig_ttl "$DNS_IP" "$APP_DOMAIN")"
[[ "$ttl" == "$P2_DNS_TTL" ]] && ok "TTL in the answer = ${ttl}s (Phase 1 was ${DNS_TTL}s)" \
  || die "TTL is '$ttl', expected $P2_DNS_TTL"

cat <<NEXT

  ${C_BLD}Primary now serves TTL ${P2_DNS_TTL}s.${C_OFF} See it in the ANSWER section:
      dig $APP_DOMAIN            # second column of the ANSWER = TTL
  Roll back to the exact Phase 1 config:
      make p2-rollback WHAT=primary-dns

NEXT
