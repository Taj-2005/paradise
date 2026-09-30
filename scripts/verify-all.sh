#!/usr/bin/env bash
# THE acceptance test. Run from a CLIENT machine (Mac 1, 3 or 4 — not Mac 2).
#
# Every check here maps to something the evaluator looks at. If this passes,
# Phase 1 is done. Exit code is non-zero if anything failed, so it is usable
# in a pre-demo checklist.
#
#   ./scripts/verify-all.sh
#
# Deliberately uses the real domain name and never -k, exactly as the form
# requires. If a check fails because of that, the check is right and the
# system is wrong.

source "$(dirname "$0")/lib/common.sh"
load_env

hdr "Phase 1 acceptance — $TEAM — from $(hostname -s) ($(my_ip))"

if [[ "$(my_role)" == "mac2-edge" ]]; then
  warn "You are on the EDGE machine. Form field A3 requires client-side proof."
  warn "Re-run this from Mac 1, 3 or 4 before collecting evidence."
fi

# ════════ A — LAN and DNS ════════════════════════════════════════════════
step "A · LAN and private DNS"

for spec in "Mac1 DNS:$DNS_IP" "Mac2 Edge:$EDGE_IP" "Mac3 A:$BACKEND_A_IP" "Mac4 B:$BACKEND_B_IP"; do
  IFS=: read -r label ip <<< "$spec"
  [[ "$ip" == "$(my_ip)" ]] && continue
  check "ping $label ($ip)" ping -c2 -W1000 "$ip"
done

DIG="$(dig "$APP_DOMAIN" 2>/dev/null)"
check_contains "$APP_DOMAIN resolves to the edge ($EDGE_IP)" "$DIG" "$EDGE_IP"
# The SERVER line is explicitly checked by the evaluator in form field A3.
check_contains "answer came from our DNS server ($DNS_IP)"   "$DIG" "SERVER: $DNS_IP"
check_contains "dig reports NOERROR"                          "$DIG" "status: NOERROR"

DIG_API="$(dig "$API_DOMAIN" 2>/dev/null)"
check_contains "$API_DOMAIN resolves to the edge"             "$DIG_API" "$EDGE_IP"

# A4: the name must NOT exist on the public internet.
PUB="$(dig @8.8.8.8 "$APP_DOMAIN" 2>/dev/null || true)"
if printf '%s' "$PUB" | grep -q "status: NXDOMAIN"; then
  ok "public DNS returns NXDOMAIN — the name is genuinely private"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  # A timeout is also an acceptable result per the form.
  if [[ -z "$(dig +short @8.8.8.8 "$APP_DOMAIN" 2>/dev/null)" ]]; then
    ok "public DNS returns no answer — the name is private"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    err "public DNS ANSWERED for $APP_DOMAIN — that is not a private name"
    FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_CHECKS+=("public NXDOMAIN")
  fi
fi

# ════════ B — HTTPS, reverse proxy, load balancing ═══════════════════════
step "B · HTTPS and load balancing"

# NOTE: no -k, and the domain name rather than an IP. Both are hard rules.
V="$(curl -sv --max-time 10 "$APP_URL/api/status" 2>&1 || true)"
check_icontains "TLS handshake completed"                  "$V" "SSL connection using"
check_icontains "certificate verified (no -k needed)"      "$V" "SSL certificate verify ok"
check_icontains "certificate is for $APP_DOMAIN"           "$V" "$APP_DOMAIN"
check_icontains "HTTP 200 returned"                        "$V" "200"
check_not_contains "TLS verification was NOT skipped"      "$V" "verification SKIPPED"

# Prove we connected to the edge by name, and that DNS is what got us there.
check_icontains "connected to $APP_DOMAIN at $EDGE_IP"     "$V" "$EDGE_IP"

SEEN=""
for _ in 1 2 3 4 5 6; do
  SEEN="$SEEN$(curl -s -D - -o /dev/null --max-time 5 "$APP_URL/api/status" 2>/dev/null \
      | awk -F': ' 'tolower($1)=="x-backend"{gsub(/\r/,"");printf "%s",$2}')"
done
info "six requests served by: ${SEEN:-<none>}"
check_contains "Backend A appears"                         "$SEEN" "A"
check_contains "Backend B appears"                         "$SEEN" "B"

# The client must never need a backend address. If these are reachable the
# system still works, but Phase 2 Extension C will have to close them.
if nc -z -G2 "$BACKEND_A_IP" "$BACKEND_A_PORT" >/dev/null 2>&1; then
  info "note: backend A is directly reachable from here (fine for Phase 1; Extension C closes this)"
fi

# ════════ C — the request path is what we claim ══════════════════════════
step "C · request path"

# Requesting by IP must fail: it proves name-based routing is real and that
# the spec's "never by IP" rule is enforced at the server, not by convention.
IPTEST="$(curl -sk --max-time 5 "https://$EDGE_IP:$HTTPS_PORT/api/status" 2>&1 || true)"
if printf '%s' "$IPTEST" | grep -qi 'empty reply\|Recv failure\|reset by peer'; then
  ok "requests by IP are refused (default_server 444)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  warn "requests by IP were not refused — check the default_server block"
fi

check_icontains "edge identifies itself"  "$(curl -sI --max-time 5 "$APP_URL/api/status")" "x-edge"

# ════════ D — caching ════════════════════════════════════════════════════
step "D · HTTP caching (Task F)"

H="$(curl -sI --max-time 5 "$APP_URL/api/status")"
check_icontains "Cache-Control present"                    "$H" "max-age=$CACHE_MAX_AGE"
check_icontains "ETag present"                             "$H" "etag"
check_icontains "Date present"                             "$H" "date"
check_icontains "X-Backend present"                        "$H" "x-backend"

# The 304 demo runs against /api/cacheable, whose body is byte-identical on
# both backends. /api/status embeds the backend id, so its ETag differs per
# replica and round-robin would make the 304 intermittent.
ETAG="$(curl -sI --max-time 5 "$APP_URL/api/cacheable" \
        | awk -F': ' 'tolower($1)=="etag"{gsub(/\r/,"");print $2}' | head -1)"
CODES=""
for _ in 1 2 3 4; do
  CODES="$CODES$(curl -s -o /dev/null -w '%{http_code} ' --max-time 5 \
    -H "If-None-Match: $ETAG" "$APP_URL/api/cacheable")"
done
info "conditional requests returned: $CODES"
check_contains     "304 Not Modified returned"             "$CODES" "304"
check_not_contains "304 is stable across both backends"    "$CODES" "200"

NOCACHE="$(curl -sI --max-time 5 "$APP_URL/api/time")"
check_icontains "uncacheable endpoint says no-store"       "$NOCACHE" "no-store"

# ════════ E — failure behaviour is available ═════════════════════════════
step "E · readiness for the failure demo"

check "edge health endpoint answers" \
  curl -sf --max-time 5 "$APP_URL/edge-health"

if curl -sf --max-time 3 "http://$BACKEND_A_IP:$BACKEND_A_PORT/healthz" >/dev/null 2>&1 \
&& curl -sf --max-time 3 "http://$BACKEND_B_IP:$BACKEND_B_PORT/healthz" >/dev/null 2>&1; then
  ok "both backends healthy — 'make demo-fail' will work"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  err "one or both backends are not healthy; the failure demo needs both up first"
  FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_CHECKS+=("both backends healthy")
fi

echo
summary
