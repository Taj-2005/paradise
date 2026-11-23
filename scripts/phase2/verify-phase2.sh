#!/usr/bin/env bash
# [client — Mac 1 recommended]  Phase 2 acceptance test. NON-DESTRUCTIVE.
#
# Asserts the steady state of every extension. The demos (failover, cutover,
# HA) change things on purpose; this only reads. Run it before and after demos.

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

ev_open "verify-phase2-$(date +%Y%m%d-%H%M%S).txt" "Phase 2 acceptance (verify-phase2.sh)"

# Mirror every check line into the evidence file as well as the screen, so the
# saved file shows WHICH checks passed, not only the final tally. (Shadowing the
# print helpers keeps PASS_COUNT in this shell; a `| tee` would lose it.)
ok()   { printf '%s✓%s %s\n' "$C_GRN" "$C_OFF" "$*";      printf '✓ %s\n' "$*" | _ev_strip >> "$EV_FILE"; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; printf '✗ %s\n' "$*" | _ev_strip >> "$EV_FILE"; }
info() { printf '%s→%s %s\n' "$C_BLU" "$C_OFF" "$*";      printf '→ %s\n' "$*" | _ev_strip >> "$EV_FILE"; }
step() { printf '\n%s%s%s\n' "$C_BLD" "$*" "$C_OFF";     printf '\n%s\n' "$*" >> "$EV_FILE"; }

hdr "Phase 2 verification from $(my_ip) ($(my_role))"
is_edge && warn "Run this from a client, not the edge — Ext C expects a NON-edge vantage point."

TARGET_NOW="$(dig_a "$DNS_IP" "$APP_DOMAIN")"

step "A · Backup DNS resolver"
res="$(networksetup -getdnsservers "$NET_SERVICE" 2>/dev/null | tr '\n' ' ')"
check_contains "client resolvers include primary $DNS_IP"   "$res" "$DNS_IP"
check_contains "client resolvers include backup $BACKUP_DNS_IP" "$res" "$BACKUP_DNS_IP"
p="$(dig_a "$DNS_IP" "$APP_DOMAIN")"; b="$(dig_a "$BACKUP_DNS_IP" "$APP_DOMAIN")"
check "primary $DNS_IP answers $APP_DOMAIN"        test -n "$p"
check "backup $BACKUP_DNS_IP answers $APP_DOMAIN"  test -n "$b"
check "primary and backup return the same record ($p / $b)" test "$p" = "$b"
check "backup answers $API_DOMAIN too" test -n "$(dig_a "$BACKUP_DNS_IP" "$API_DOMAIN")"
check "backup still forwards public names (example.com)" test -n "$(dig_a "$BACKUP_DNS_IP" example.com)"

step "B · TTL"
check "primary serves TTL ${P2_DNS_TTL}s" test "$(dig_ttl "$DNS_IP" "$APP_DOMAIN")" = "$P2_DNS_TTL"
check "backup serves TTL ${P2_DNS_TTL}s"  test "$(dig_ttl "$BACKUP_DNS_IP" "$APP_DOMAIN")" = "$P2_DNS_TTL"
check "record points at a known edge ($TARGET_NOW)" \
  bash -c "[[ '$TARGET_NOW' == '$EDGE_IP' || '$TARGET_NOW' == '$STANDBY_EDGE_IP' ]]"

step "C · Service isolation (direct backend ports from this client)"
if is_edge || is_standby_edge; then
  info "skipped — this machine is an edge and is ALLOWED through"
else
  for pair in "A $BACKEND_A_IP $BACKEND_A_PORT" "B $BACKEND_B_IP $BACKEND_B_PORT"; do
    set -- $pair
    [[ "$2" == "$(my_ip)" ]] && { info "Backend $1 is this machine — skipped"; continue; }
    rc=0; curl -s -o /dev/null --connect-timeout 3 --max-time 4 "http://$2:$3/healthz" || rc=$?
    check "direct $2:$3 is filtered (timeout, curl 28) — got curl $rc" test "$rc" -eq 28
  done
fi

step "D · Load balancing + failover readiness (through the edge, by name)"
seen=""; codes=""
for _ in 1 2 3 4 5 6; do one_request "$APP_URL/api/status"; seen="$seen${REQ_BACKEND:-?}"; codes="$codes$REQ_CODE "; done
info "6 requests: $seen   codes: $codes"
check_contains "Backend A in rotation" "$seen" "A"
check_contains "Backend B in rotation" "$seen" "B"
check_not_contains "no failed requests" "$codes" "50"
up="$(curl -s -o /dev/null -w '%{http_code}' --resolve "$APP_DOMAIN:$HTTPS_PORT:$EDGE_IP" "https://$APP_DOMAIN:$HTTPS_PORT/edge-health" || true)"
check "primary edge /edge-health = 200" test "$up" = 200

step "E · Standby edge (pinned with --resolve, TLS verified, no -k)"
raw="$(curl -s -D - -o /dev/null --max-time 5 --resolve "$APP_DOMAIN:$HTTPS_PORT:$STANDBY_EDGE_IP" \
        "https://$APP_DOMAIN:$HTTPS_PORT/api/status" 2>/dev/null || true)"
check_contains  "standby edge answers 200"                     "$(printf '%s' "$raw" | head -1)" "200"
check_icontains "standby identifies itself (X-Edge nginx@$STANDBY_EDGE_IP)" "$raw" "nginx@$STANDBY_EDGE_IP"
check_icontains "standby reaches the backends (X-Backend present)" "$raw" "x-backend:"

step "F · Troubleshooting tooling"
check "diagnose.sh present and parses" bash -n "$P2_SCRIPTS/diagnose.sh"

{ echo; echo "Result: $PASS_COUNT passed, $FAIL_COUNT failed"; } | tee -a "$EV_FILE" >/dev/null
ev_close
p2_summary "Phase 2 acceptance"
