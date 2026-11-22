#!/usr/bin/env bash
# [Mac 1 AND the backup DNS]  Extensions B + E — change where the A records point.
#
#   ./dns-cutover.sh standby     # app/api -> standby edge   (Ext E migration)
#   ./dns-cutover.sh primary     # app/api -> Mac 2           (cut back)
#   ./dns-cutover.sh 10.x.y.z    # any IP (used by the fault injector)
#
# Run it on BOTH DNS servers. Clients ask the primary first, so the visible
# behaviour follows Mac 1 — but a backup that still holds the old record would
# send clients to the wrong edge the moment the primary fails.
# (In production the secondary would pick this up by zone transfer.)

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

case "${1:-}" in
  standby) TARGET="$STANDBY_EDGE_IP" ;;
  primary) TARGET="$EDGE_IP" ;;
  [0-9]*.[0-9]*.[0-9]*.[0-9]*) TARGET="$1" ;;
  *) die "Usage: $(basename "$0") standby|primary|<ipv4>   (make p2-cutover TO=standby)" ;;
esac

if   is_primary_dns; then WHICH=primary; CONF="$P2_PRIMARY_DNS_CONF"; OTHER="$BACKUP_DNS_IP (backup DNS)"
elif is_backup_dns;  then WHICH=backup;  CONF="$P2_BACKUP_DNS_CONF";  OTHER="$DNS_IP (Mac 1, primary DNS)"
else die "This machine ($(my_ip)) is neither the primary ($DNS_IP) nor the backup ($BACKUP_DNS_IP) DNS."
fi

OLD="$(edge_target_ip)"
hdr "DNS cutover on the $WHICH DNS: $OLD -> $TARGET"
info "old: $OLD  ($(edge_label "$OLD"))"
info "new: $TARGET  ($(edge_label "$TARGET"))"
info "TTL: ${P2_DNS_TTL}s — clients that cached the old answer keep using it for up to ${P2_DNS_TTL}s"

render_dns_profile "$WHICH" "$TARGET"
dnsmasq_install_conf "$CONF"
dnsmasq_restart
set_edge_target "$TARGET"

ip="$(my_ip)"
got="$(dig_a "$ip" "$APP_DOMAIN")"
[[ "$got" == "$TARGET" ]] && ok "This server now answers $APP_DOMAIN -> $got  ($(date +%H:%M:%S))" \
  || die "Server answers '$got', expected $TARGET"

cat <<NEXT

  ${C_BLD}Now do the same on $OTHER:${C_OFF}
      make p2-cutover TO=${1}

  On a client, watch the cut-over happen (dig flips now, the OS cache flips
  only after the TTL expires):
      make p2-ttl-watch
  Skip the wait on a client:
      make p2-flush

NEXT
