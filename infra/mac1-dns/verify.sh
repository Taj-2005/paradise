#!/usr/bin/env bash
# Mac 1 — verify the DNS server is answering correctly.
# Run on Mac 1 for a local check; run scripts/verify-all.sh from a CLIENT for
# the check that actually counts (spec A3 requires client-side proof).

source "$(dirname "$0")/../../scripts/lib/common.sh"
load_env

hdr "DNS verification — $TEAM"

step "1. Service state"
sudo brew services list 2>/dev/null | grep -E '^(Name|dnsmasq)' || warn "brew services unavailable"

step "2. Listening sockets (expect 0.0.0.0:53, NOT 127.0.0.1:53)"
sudo lsof -nP -iUDP:53 -iTCP:53 2>/dev/null | grep -i dnsmasq || warn "dnsmasq not bound to :53"

step "3. Forward records"
for name in "$APP_DOMAIN" "$API_DOMAIN"; do
  got="$(dig +short +time=2 +tries=1 "@$DNS_IP" "$name" | head -1)"
  if [[ "$got" == "$EDGE_IP" ]]; then ok "$name -> $got"
  else err "$name -> '${got:-<no answer>}' (expected $EDGE_IP)"; fi
done

step "4. Upstream forwarding still works (clients need normal internet)"
if [[ -n "$(dig +short +time=3 +tries=1 "@$DNS_IP" example.com A | head -1)" ]]; then
  ok "example.com resolves through us -> upstream $UPSTREAM_DNS"
else
  err "Upstream forwarding is broken — clients will lose internet access."
fi

step "5. The name must NOT exist publicly (spec A4)"
pub="$(dig +short +time=3 +tries=1 @8.8.8.8 "$APP_DOMAIN" 2>/dev/null | head -1)"
if [[ -z "$pub" ]]; then ok "@8.8.8.8 returns no answer — the name is private"
else err "@8.8.8.8 answered '$pub' — that is not a private name"; fi

step "6. Recent queries seen by this server"
tail -15 "$BREW_PREFIX/var/log/dnsmasq.log" 2>/dev/null | sed 's/^/    /' \
  || warn "No log yet at $BREW_PREFIX/var/log/dnsmasq.log"

echo
