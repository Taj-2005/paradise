#!/usr/bin/env bash
# [client]  Extension D — continuous traffic while a backend dies and returns.
#
#   ./ha-demo.sh          # 60 s, one request every 0.5 s
#   ./ha-demo.sh 90
#
# Choreography (printed on screen too):
#   ~10 s  Mac 3: Ctrl-C Backend A       → every response becomes X-Backend: B
#   ~35 s  Mac 3: make backend-a         → after fail_timeout (≤10 s) A rejoins
# Pass criteria: zero non-200 responses, B-only during the outage, A and B
# both present again at the end.

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

DURATION="${1:-60}"
ev_open "D-ha-failover/D-ha-demo-$(date +%Y%m%d-%H%M%S).txt" "Extension D — HA failover under continuous traffic"
hdr "Extension D — HA failover   ($DURATION s of traffic to $APP_URL/api/status)"
cat <<PLAN
  ${C_YEL}${C_BLD}Choreography${C_OFF}
    at ~10s   on Mac 3:  Ctrl-C the Backend A process
    at ~35s   on Mac 3:  make backend-a
    (on Mac 2, 'make p2-health-watch' shows the edge's view live)

PLAN
read -rp "  Press Enter to start the traffic… " _

start=$(date +%s); end=$(( start + DURATION ))
seq_all=""; bad=0; n=0; a=0; b=0; retried=0
while (( $(date +%s) < end )); do
  one_request "$APP_URL/api/status"
  n=$((n+1)); t=$(( $(date +%s) - start ))
  case "$REQ_BACKEND" in A) a=$((a+1));; B) b=$((b+1));; esac
  [[ "$REQ_CODE" == 200 ]] || bad=$((bad+1))
  seq_all="$seq_all${REQ_BACKEND:-x}"
  # "A:3001, B:3002" in $upstream_addr = nginx tried A, it failed, retried on B.
  [[ "${REQ_UPSTREAM:-}" == *":$BACKEND_A_PORT, "* ]] && retried=$((retried+1))
  col="$C_GRN"; [[ "$REQ_CODE" == 200 ]] || col="$C_RED"
  # One request per tick, and everything read from THAT response: a second
  # request per loop would pair up with round robin and pin /api/status to
  # one backend, faking a failover that never happened.
  ev_note "$(printf '%3ss  #%-4s %sHTTP %s%s  X-Backend: %-2s  upstream=%s' "$t" "$n" "$col" "$REQ_CODE" "$C_OFF" "${REQ_BACKEND:--}" "${REQ_UPSTREAM:--}")"
  sleep 0.5
done

tail10="${seq_all: -10}"
ev_note ""
ev_note "Requests: $n   Backend A: $a   Backend B: $b   non-200: $bad   retried off A: $retried"
ev_note "Sequence: $seq_all"
ev_note "Last 10 : $tail10"
ev_close

check              "service never failed (zero non-200 responses)" test "$bad" -eq 0
check_contains     "Backend B carried traffic"                       "$seq_all" "B"
# Round robin alone produces B-runs of 4–5 by chance, so a short run proves
# nothing. Require ~10 s of B-only AND nginx itself recording a failed try on A.
check_contains     "an outage window was B-only (15+ consecutive B)" "$seq_all" "BBBBBBBBBBBBBBB"
check              "nginx saw Backend A fail and retried on B ($retried times)" test "$retried" -gt 0
check_contains     "Backend A back in rotation at the end"           "$tail10" "A"
check_contains     "Backend B still in rotation at the end"          "$tail10" "B"
p2_summary "Extension D HA failover"
