#!/usr/bin/env bash
# Any client Mac (2, 3 or 4) — point this machine's resolver at Mac 1.
# Spec Task B: "Configure at least two other Macs to use Mac 1 as their DNS resolver."

source "$(dirname "$0")/../../scripts/lib/common.sh"
load_env

hdr "Point DNS at Mac 1 ($DNS_IP)"

# Save whatever was configured before, so reset-dns.sh can put it back exactly.
# macOS reports "There aren't any DNS Servers set..." when the service is on
# DHCP-supplied DNS; we normalise that to the literal "Empty", which is what
# networksetup expects as the argument to clear it again.
BACKUP="$REPO_ROOT/.dns-backup-$NET_SERVICE.txt"
if [[ ! -f "$BACKUP" ]]; then
  current="$(networksetup -getdnsservers "$NET_SERVICE" 2>/dev/null)"
  [[ "$current" == *"aren't any DNS Servers"* ]] && current="Empty"
  printf '%s\n' "$current" > "$BACKUP"
  ok "Saved previous DNS setting -> $(basename "$BACKUP")"
  printf '%s\n' "$current" | sed 's/^/      /'
fi

info "Setting DNS for network service '$NET_SERVICE' to $DNS_IP"
sudo networksetup -setdnsservers "$NET_SERVICE" "$DNS_IP"

# macOS caches aggressively. Without this flush the old answers persist and
# you spend twenty minutes debugging a resolver that is already correct.
info "Flushing the DNS cache…"
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder 2>/dev/null || true

step "Confirming"
networksetup -getdnsservers "$NET_SERVICE" | sed 's/^/    /'

got="$(dig +short +time=3 +tries=1 "$APP_DOMAIN" | head -1)"
if [[ "$got" == "$EDGE_IP" ]]; then
  ok "$APP_DOMAIN -> $got   (resolved through Mac 1)"
else
  err "$APP_DOMAIN -> '${got:-<no answer>}' (expected $EDGE_IP)"
  err "Check on Mac 1:  ./infra/mac1-dns/verify.sh"
  err "Check reachability:  ping -c2 $DNS_IP"
  exit 1
fi

# The SERVER line is what the evaluator checks in A3 — it must be Mac 1, not
# the router and not 8.8.8.8. Show it now so there are no surprises later.
srv="$(dig "$APP_DOMAIN" | awk '/^;; SERVER:/{print $3}')"
info "dig reports SERVER: $srv"
[[ "$srv" == "$DNS_IP"* ]] && ok "Queries are going to Mac 1" \
  || warn "SERVER is not $DNS_IP — the evaluator checks this line in A3."

cat <<NEXT

  Restore the original setting at any time:
      ./infra/client/reset-dns.sh

NEXT
