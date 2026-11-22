#!/usr/bin/env bash
# [any — offline]  Static tests for Phase 2. No LAN, no running services needed.
#
#   1. every Phase 2 script parses (bash -n)
#   2. every profile renders from the Phase 1 templates, no {{leftovers}}
#   3. rendered profiles contain the values they must (TTL, records, allow-list)
#   4. dnsmasq / pf parsers accept them (if the tools and sudo are available)
#   5. Phase 1 is untouched (git diff on Phase 1 paths is empty)

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

hdr "Phase 2 offline tests"

step "1 · Script syntax"
for f in "$P2_SCRIPTS"/*.sh "$P2_SCRIPTS"/lib/*.sh; do
  check "bash -n ${f#"$REPO_ROOT"/}" bash -n "$f"
done

step "2 · Rendering"
"$P2_SCRIPTS/render-phase2.sh" >/dev/null 2>&1
for f in "$P2_PRIMARY_DNS_CONF" "$P2_BACKUP_DNS_CONF" "$P2_STANDBY_NGX_CONF" "$P2_STANDBY_SITE_CONF" "$P2_PF_A_CONF" "$P2_PF_B_CONF"; do
  check "rendered ${f#"$REPO_ROOT"/}" test -s "$f"
  check "no {{placeholders}} in $(basename "$(dirname "$f")")/$(basename "$f")" bash -c "! grep -q '{{[A-Z_]*}}' '$f'"
done

step "3 · Content"
T="$(edge_target_ip)"
check_contains "primary DNS: local-ttl=$P2_DNS_TTL" "$(cat "$P2_PRIMARY_DNS_CONF")" "local-ttl=$P2_DNS_TTL"
check_contains "backup DNS:  local-ttl=$P2_DNS_TTL" "$(cat "$P2_BACKUP_DNS_CONF")"  "local-ttl=$P2_DNS_TTL"
check_contains "backup DNS:  $APP_DOMAIN -> $T"     "$(cat "$P2_BACKUP_DNS_CONF")"  "address=/$APP_DOMAIN/$T"
check_contains "backup DNS:  listens on all interfaces" "$(cat "$P2_BACKUP_DNS_CONF")" "listen-address=0.0.0.0"
check_contains "backup DNS:  independent (no-resolv, upstream $UPSTREAM_DNS only)" "$(cat "$P2_BACKUP_DNS_CONF")" "server=$UPSTREAM_DNS"
check_not_contains "backup DNS:  does NOT forward to Mac 1" "$(cat "$P2_BACKUP_DNS_CONF")" "server=$DNS_IP"
check_contains "standby edge: X-Edge identifies $STANDBY_EDGE_IP" "$(cat "$P2_STANDBY_SITE_CONF")" "nginx@$STANDBY_EDGE_IP"
check_contains "standby edge: same upstream A"     "$(cat "$P2_STANDBY_SITE_CONF")" "$BACKEND_A_IP:$BACKEND_A_PORT"
check_contains "standby edge: same upstream B"     "$(cat "$P2_STANDBY_SITE_CONF")" "$BACKEND_B_IP:$BACKEND_B_PORT"
check_contains "standby edge: cert from infra/phase2/certs" "$(cat "$P2_STANDBY_SITE_CONF")" "$P2_CERT_DIR/$APP_DOMAIN.crt"
check_contains "pf A: allows both edges on :$BACKEND_A_PORT" "$(cat "$P2_PF_A_CONF")" "{ $EDGE_IP, $STANDBY_EDGE_IP } to any port $BACKEND_A_PORT"
check_contains "pf A: drops everyone else"         "$(cat "$P2_PF_A_CONF")" "block drop in quick proto tcp from any to any port $BACKEND_A_PORT"
check_contains "pf B: drops everyone else"         "$(cat "$P2_PF_B_CONF")" "block drop in quick proto tcp from any to any port $BACKEND_B_PORT"
check "pf: allow rule precedes block rule (order matters with quick)" bash -c \
  "[[ \$(grep -n '^pass in quick proto tcp' '$P2_PF_A_CONF' | cut -d: -f1) -lt \$(grep -n '^block drop' '$P2_PF_A_CONF' | cut -d: -f1) ]]"

step "4 · Native parsers (skipped when unavailable)"
if command -v dnsmasq >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  check "dnsmasq --test primary profile" bash -c "sudo dnsmasq --test --conf-file='$P2_PRIMARY_DNS_CONF' 2>&1 | grep -q 'syntax check OK'"
  check "dnsmasq --test backup profile"  bash -c "sudo dnsmasq --test --conf-file='$P2_BACKUP_DNS_CONF'  2>&1 | grep -q 'syntax check OK'"
else info "dnsmasq parse skipped (no dnsmasq here, or sudo needs a password — run 'sudo -v' first)"; fi
if sudo -n true 2>/dev/null; then
  check "pfctl -n parses Backend A rules" sudo pfctl -a "$PF_ANCHOR-test" -nf "$P2_PF_A_CONF"
  check "pfctl -n parses Backend B rules" sudo pfctl -a "$PF_ANCHOR-test" -nf "$P2_PF_B_CONF"
else info "pfctl parse skipped (run 'sudo -v' first to include it)"; fi
if command -v nginx >/dev/null 2>&1 && [[ -f "$P2_CERT_DIR/$APP_DOMAIN.crt" ]]; then
  # Test the standby pair in isolation: point the include at the build dir.
  tmpc="$(mktemp -d)"; sed "s|include $BREW_PREFIX/etc/nginx/conf.d/\*.conf;|include $P2_BUILD/standby-edge/conf.d/*.conf;|; s|^error_log .*|error_log $tmpc/e.log warn;|; s|^pid .*|pid $tmpc/n.pid;|" \
    "$P2_STANDBY_NGX_CONF" > "$tmpc/nginx.conf"
  check "nginx -t accepts the standby profile" bash -c "nginx -t -c '$tmpc/nginx.conf' -e '$tmpc/e.log' 2>&1 | grep -q 'test is successful'"
  rm -rf "$tmpc"
else info "nginx -t skipped (needs nginx + infra/phase2/certs — run on the standby Mac)"; fi

step "5 · Phase 1 untouched"
if git -C "$REPO_ROOT" rev-parse >/dev/null 2>&1; then
  changed="$(git -C "$REPO_ROOT" status --porcelain -- infra services scripts .env.example ':!infra/phase2' ':!scripts/phase2' 2>/dev/null || true)"
  check "no Phase 1 changes under infra/ services/ scripts/ (phase2/ subfolders excluded)" test -z "$changed"
  [[ -n "$changed" ]] && printf '%s\n' "$changed" | sed 's/^/      /'
else info "not a git checkout — skipped"; fi

p2_summary "Phase 2 offline tests"
