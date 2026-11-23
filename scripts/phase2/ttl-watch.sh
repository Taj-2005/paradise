#!/usr/bin/env bash
# [client]  Extensions B + E — watch a DNS change propagate, every 2 seconds.
#
#   ./ttl-watch.sh            # run for 120 s (Ctrl-C to stop early)
#   ./ttl-watch.sh 60
#
# Three columns, three different truths:
#   SERVER  — `dig` asks the DNS server directly; it bypasses the OS cache, so
#             it flips the instant the record changes.
#   OS      — what macOS (mDNSResponder) hands applications; it honours the
#             TTL, so it keeps the OLD answer until the TTL expires.
#   CURL    — where a real HTTPS request actually went (remote IP + X-Edge).
# The gap between SERVER and OS is the TTL — that gap IS Extension B.

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

DURATION="${1:-120}"
ev_open "B-ttl/ttl-watch-$(date +%Y%m%d-%H%M%S).txt" "Extension B/E — TTL watch ($APP_DOMAIN, TTL ${P2_DNS_TTL}s)"

hdr "TTL watch — $APP_DOMAIN   (TTL ${P2_DNS_TTL}s, ${DURATION}s, Ctrl-C to stop)"
ev_note "Resolvers: $(networksetup -getdnsservers "$NET_SERVICE" | tr '\n' ' ')"
ev_note "Primary edge $EDGE_IP · standby edge $STANDBY_EDGE_IP"
ev_note ""
ev_note "$(printf '%-9s %-16s %-5s %-16s %-16s %-4s %-26s %s' TIME 'SERVER(dig)' TTL 'OS-CACHE' 'CURL→IP' CODE X-EDGE NOTE)"

trap 'echo; ev_close; exit 0' INT
end=$(( $(date +%s) + DURATION ))
stale_since=""
while (( $(date +%s) < end )); do
  srv="$(dig +short +time=2 +tries=1 "$APP_DOMAIN" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)"
  ttl="$(dig +noall +answer +time=2 +tries=1 "$APP_DOMAIN" A 2>/dev/null | awk '$4=="A"{print $2; exit}' || true)"
  osc="$(os_cache_ip "$APP_DOMAIN")"
  one_request "$APP_URL/api/status"

  note=""
  if [[ -n "$srv" && -n "$REQ_REMOTE" && "$srv" != "$REQ_REMOTE" ]]; then
    [[ -z "$stale_since" ]] && stale_since="$(date +%s)"
    note="${C_YEL}STALE: cache still on old edge ($(( $(date +%s) - stale_since ))s)${C_OFF}"
  elif [[ -n "$stale_since" ]]; then
    note="${C_GRN}CUT OVER after $(( $(date +%s) - stale_since ))s${C_OFF}"
    stale_since=""
  fi

  ev_note "$(printf '%-9s %-16s %-5s %-16s %-16s %-4s %-26s %s' \
    "$(date +%H:%M:%S)" "${srv:--}" "${ttl:--}" "${osc:--}" "${REQ_REMOTE:--}" \
    "$REQ_CODE" "${REQ_EDGE:--}" "$note")"
  sleep 2
done
ev_close
