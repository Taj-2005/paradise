#!/usr/bin/env bash
# [any]  Extension C — probe the backend ports directly from THIS machine.
#
# Classifies every probe by how the TCP connect failed — the transport layer
# tells you exactly what is in the way:
#   OPEN      SYN → SYN-ACK, HTTP 200             (allowed)
#   FILTERED  SYN → … nothing … timeout            (pf dropped it — a firewall)
#   CLOSED    SYN → RST, "connection refused"      (host up, nothing listening)
#
# Expectation depends on who is asking: the edges must see OPEN, everyone else
# FILTERED — and every machine must still get 200 through the edge by name.

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

me="$(my_ip)"
if is_edge || is_standby_edge; then expect=OPEN; who="an edge (allowed)"
else expect=FILTERED; who="a client (must be blocked)"; fi

ev_open "C-isolation/C-probe-from-${me:-unknown}.txt" "Extension C — direct backend probe from $me"
hdr "Extension C — probing backends from $me ($who)"

probe() {
  # probe <ip> <port>  -> echoes OPEN|FILTERED|CLOSED|ERROR:<code>
  # `|| rc=$?` — a bare `x=$(failing)` would trip the library's `set -e` and
  # abort on exactly the failure we are trying to measure.
  local rc=0 code
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 "http://$1:$2/healthz" 2>/dev/null)" || rc=$?
  case "$rc" in
    0)  [[ "$code" == 200 ]] && echo OPEN || echo "ERROR:http-$code" ;;
    28) echo FILTERED ;;
    7)  echo CLOSED ;;
    *)  echo "ERROR:curl-$rc" ;;
  esac
}

for pair in "A $BACKEND_A_IP $BACKEND_A_PORT" "B $BACKEND_B_IP $BACKEND_B_PORT"; do
  set -- $pair
  if [[ "$2" == "$me" ]]; then
    info "Backend $1 is this machine — skipping (local traffic uses lo0, which is never filtered)"
    continue
  fi
  t0=$(date +%s); res="$(probe "$2" "$3")"; dt=$(( $(date +%s) - t0 ))
  ev_note "  Backend $1  $2:$3  ->  $res   (${dt}s)"
  check_contains "direct :$3 to Backend $1 is $expect" "$res" "$expect"
done

ev_note ""
ev_note "Through the edge, by name (the only path clients should use):"
one_request "$APP_URL/api/status"
ev_note "  $APP_URL/api/status -> HTTP $REQ_CODE  X-Backend: ${REQ_BACKEND:-?}  X-Edge: ${REQ_EDGE:-?}"
check_contains "service still reachable through the edge (200)" "$REQ_CODE" "200"

ev_close
p2_summary "Extension C isolation"
