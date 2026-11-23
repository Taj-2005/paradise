#!/usr/bin/env bash
# [clients: Mac 1, Mac 3, Mac 4]  Extension A — list BOTH resolvers, primary first.
#
# Uses its own backup file, separate from Phase 1's .dns-backup-*.txt, so
# Phase 1's reset-dns.sh still restores the pre-project setting and Phase 2's
# rollback restores the Phase 1 setting. Two layers, two undo files.

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

BACKUP="$P2_STATE/client-dns-before-phase2.txt"
hdr "Resolvers for '$NET_SERVICE': $DNS_IP (primary), $BACKUP_DNS_IP (backup)"

if [[ ! -f "$BACKUP" ]]; then
  cur="$(networksetup -getdnsservers "$NET_SERVICE" 2>/dev/null)"
  [[ "$cur" == *"aren't any DNS Servers"* ]] && cur="Empty"
  printf '%s\n' "$cur" > "$BACKUP"
  ok "Saved current setting -> ${BACKUP#"$REPO_ROOT"/}"
  printf '%s\n' "$cur" | sed 's/^/      /'
fi

# Order matters: macOS tries the first server, falls through to the second
# when the first stops answering.
sudo networksetup -setdnsservers "$NET_SERVICE" "$DNS_IP" "$BACKUP_DNS_IP"
flush_client_dns
ok "Set and flushed"

step "What the OS resolver now uses"
scutil --dns 2>/dev/null | awk '/^resolver #1/{f=1} f&&/nameserver\[/{print "    "$0} /^resolver #2/{exit}'

step "Both servers answer independently"
for s in "$DNS_IP" "$BACKUP_DNS_IP"; do
  a="$(dig_a "$s" "$APP_DOMAIN")"
  [[ -n "$a" ]] && ok "@$s  $APP_DOMAIN -> $a" || warn "@$s did not answer (is dnsmasq running there?)"
done

cat <<NEXT

  Failover demo (Extension A):    make p2-demo-dns-failover
  Back to the Phase 1 setting:    make p2-rollback WHAT=client-dns

NEXT
