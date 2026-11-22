#!/usr/bin/env bash
# [Mac 2 · edge]  Extension D — live view of backend health, from the edge's side.
#
# READ-ONLY. It never changes nginx. It shows on screen what nginx's passive
# health checking (max_fails=1 fail_timeout=10s + proxy_next_upstream, from the
# Phase 1 site.conf) is reacting to, plus nginx's own upstream error lines.
#
# Why not active checks in nginx itself? The `health_check` directive exists
# only in the commercial nginx Plus. Open-source nginx detects failure from
# real traffic: a failed connect marks the server down for fail_timeout, and
# proxy_next_upstream retries the SAME request on the survivor — so the client
# never sees the failure.
#
# Deliberately does NOT send requests through nginx: that would interleave with
# the client's round robin and make the A/B sequence look wrong.

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

ERRLOG="$BREW_PREFIX/var/log/nginx/$TEAM-error.log"
ev_open "D-ha-failover/D-health-watch-$(date +%Y%m%d-%H%M%S).txt" "Extension D — backend health as seen from the edge"
hdr "Health watch — every ${HEALTH_INTERVAL}s from $(my_ip)  (Ctrl-C to stop)"

state_a=""; state_b=""; last_err=""
check_one() {
  # check_one <ip> <port>  -> "UP 12ms" | "DOWN (refused)" | "DOWN (timeout)"
  local rc=0 out
  out="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --connect-timeout 1 --max-time 2 "http://$1:$2/healthz" 2>/dev/null)" || rc=$?
  case "$rc" in
    0) set -- $out; [[ "$1" == 200 ]] && printf 'UP   %4sms' "$(awk -v t="$2" 'BEGIN{printf "%d", t*1000}')" || printf 'DOWN (HTTP %s)' "$1" ;;
    7) printf 'DOWN (refused)' ;;
    28) printf 'DOWN (timeout)' ;;
    *) printf 'DOWN (curl %s)' "$rc" ;;
  esac
}

trap 'echo; ev_close; exit 0' INT
ev_note "$(printf '%-9s %-24s %-24s %s' TIME "A $BACKEND_A_IP:$BACKEND_A_PORT" "B $BACKEND_B_IP:$BACKEND_B_PORT" EVENT)"
while :; do
  a="$(check_one "$BACKEND_A_IP" "$BACKEND_A_PORT")"
  b="$(check_one "$BACKEND_B_IP" "$BACKEND_B_PORT")"
  ev=""
  [[ -n "$state_a" && "${a%% *}" != "${state_a%% *}" ]] && ev="${ev}A went ${a%% *}  "
  [[ -n "$state_b" && "${b%% *}" != "${state_b%% *}" ]] && ev="${ev}B went ${b%% *}  "
  state_a="$a"; state_b="$b"

  # nginx's own view: newest upstream complaint in the error log
  if [[ -r "$ERRLOG" ]]; then
    e="$(tail -n 50 "$ERRLOG" 2>/dev/null | grep -E 'upstream|no live upstreams' | tail -1 || true)"
    if [[ -n "$e" && "$e" != "$last_err" ]]; then
      ev="${ev}nginx: $(printf '%s' "$e" | sed -E 's/.*\[(error|warn)\] [0-9#*]+ //' | cut -c1-90)"
      last_err="$e"
    fi
  fi

  ca="$C_GRN"; [[ "$a" == DOWN* ]] && ca="$C_RED"
  cb="$C_GRN"; [[ "$b" == DOWN* ]] && cb="$C_RED"
  ev_note "$(printf '%-9s %s%-24s%s %s%-24s%s %s' "$(date +%H:%M:%S)" "$ca" "$a" "$C_OFF" "$cb" "$b" "$C_OFF" "$ev")"
  sleep "$HEALTH_INTERVAL"
done
