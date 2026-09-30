#!/usr/bin/env bash
# Load-balancing proof — spec Task D, form field B2.
#
#   ./scripts/lb-check.sh        # 6 requests (what the form asks for)
#   ./scripts/lb-check.sh 20     # more, to show the distribution
#
# Asserts that BOTH backends appear. One backend answering every request is a
# failure, not a pass — it means round-robin is not working or one upstream is
# already down.

source "$(dirname "$0")/lib/common.sh"
load_env

N="${1:-6}"

hdr "Load balancing — $N consecutive requests to $APP_URL/api/status"

seen=""
a=0; b=0; other=0
for i in $(seq 1 "$N"); do
  # -s silent, -D - dumps headers to stdout. We read X-Backend case-
  # insensitively because HTTP/2 lowercases all header names.
  hdrs="$(curl -s -D - -o /dev/null --max-time 5 "$APP_URL/api/status" 2>/dev/null || true)"
  who="$(printf '%s' "$hdrs" | awk -F': ' 'tolower($1)=="x-backend"{gsub(/\r/,"");print $2}' | head -1)"
  code="$(printf '%s' "$hdrs" | awk 'NR==1{print $2}')"
  up="$(printf '%s' "$hdrs" | awk -F': ' 'tolower($1)=="x-upstream-addr"{gsub(/\r/,"");print $2}' | head -1)"

  case "$who" in
    A) a=$((a+1)) ;;
    B) b=$((b+1)) ;;
    *) other=$((other+1)) ;;
  esac
  seen="$seen${who:-?}"
  printf '  %2d.  HTTP %-4s X-Backend: %-3s upstream=%s\n' "$i" "${code:----}" "${who:-?}" "${up:-?}"
done

echo
info "Sequence: $seen"
info "Backend A: $a    Backend B: $b    unidentified: $other"
echo

check_contains "Backend A served at least one request" "$seen" "A"
check_contains "Backend B served at least one request" "$seen" "B"
check_not_contains "every request was attributed"      "$seen" "?"

summary
