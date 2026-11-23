#!/usr/bin/env bash
# Extension F — PRACTICE faults, so the team rehearses before faculty inject one.
# Every fault has an exact undo. One teammate injects, another diagnoses with
# `make p2-diagnose` without being told which fault it is.
#
#   ./inject-fault.sh list
#   ./inject-fault.sh <fault>          # inject
#   ./inject-fault.sh <fault> undo     # restore

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

BOGUS_IP="${BOGUS_IP:-10.255.255.1}"     # an address nobody on the LAN owns
FAULT_ANCHOR="com.apple/251.ParadiseFault"
MARK="# paradise-p2-fault"

list() {
  cat <<LIST
  ${C_BLD}fault             run on      layer it breaks              symptom${C_OFF}
  hosts-override    client      DNS (local /etc/hosts)       dig fine, curl hangs — OS ignores DNS
  client-dns-wrong  client      DNS (resolver config)        NXDOMAIN; ping to edge IP still works
  dns-wrong-ip      Mac 1       DNS (record data)            resolves to $BOGUS_IP; connect times out
  dns-down          Mac 1       DNS (service)                NONE if backup works — resilience!
  edge-down         Mac 2       Transport (closed port)      connection refused on :$HTTPS_PORT
  edge-filtered     Mac 2       Transport (firewall)         connection timed out on :$HTTPS_PORT
  backend-filtered  Mac 3 / 4   Application (upstream)       one: none (HA) · both: 502/504

  inject:  make p2-fault F=<fault>        undo:  make p2-fault-undo F=<fault>
LIST
}

SUDO=""; (( HTTPS_PORT < 1024 )) && SUDO="sudo"
state() { echo "$P2_STATE/fault-$1"; }

pf_block_port() { # pf_block_port <port>
  printf 'block drop in quick proto tcp from any to any port %s\n' "$1" > "$P2_STATE/fault-pf.conf"
  sudo pfctl -a "$FAULT_ANCHOR" -f "$P2_STATE/fault-pf.conf" 2>/dev/null
  sudo pfctl -E 2>&1 | awk '/Token/{print $NF}' > "$P2_STATE/fault-pf-token" || true
}
pf_unblock() {
  sudo pfctl -a "$FAULT_ANCHOR" -F all 2>/dev/null || true
  [[ -s "$P2_STATE/fault-pf-token" ]] && sudo pfctl -X "$(cat "$P2_STATE/fault-pf-token")" 2>/dev/null || true
  rm -f "$P2_STATE/fault-pf-token" "$P2_STATE/fault-pf.conf"
}

F="${1:-list}"; MODE="${2:-inject}"
[[ "$F" == list ]] && { list; exit 0; }

hdr "Fault '$F' — $MODE"
case "$F:$MODE" in
  hosts-override:inject)
    printf '%s %s %s\n' "$BOGUS_IP" "$APP_DOMAIN" "$MARK" | sudo tee -a /etc/hosts >/dev/null
    flush_client_dns; touch "$(state "$F")" ;;
  hosts-override:undo)
    sudo sed -i '' "/$MARK\$/d" /etc/hosts; flush_client_dns; rm -f "$(state "$F")" ;;

  client-dns-wrong:inject)
    networksetup -getdnsservers "$NET_SERVICE" > "$(state "$F")"
    sudo networksetup -setdnsservers "$NET_SERVICE" 8.8.8.8; flush_client_dns ;;
  client-dns-wrong:undo)
    [[ -f "$(state "$F")" ]] || die "No saved resolver list — use make p2-client-dns"
    servers=(); while IFS= read -r l; do [[ -n "$l" && "$l" != *"aren't any"* ]] && servers+=("$l"); done < "$(state "$F")"
    [[ ${#servers[@]} -gt 0 ]] || servers=(Empty)
    sudo networksetup -setdnsservers "$NET_SERVICE" "${servers[@]}"; flush_client_dns; rm -f "$(state "$F")" ;;

  dns-wrong-ip:inject)
    edge_target_ip > "$(state "$F")"
    "$(dirname "$0")/dns-cutover.sh" "$BOGUS_IP" ;;
  dns-wrong-ip:undo)
    prev="$(cat "$(state "$F")" 2>/dev/null || echo "$EDGE_IP")"
    "$(dirname "$0")/dns-cutover.sh" "$prev"; rm -f "$(state "$F")" ;;

  dns-down:inject) dnsmasq_stop; touch "$(state "$F")"; ok "dnsmasq stopped" ;;
  dns-down:undo)   dnsmasq_restart; rm -f "$(state "$F")" ;;

  edge-down:inject) $SUDO nginx -s stop; touch "$(state "$F")"; ok "nginx stopped" ;;
  edge-down:undo)   $SUDO nginx; rm -f "$(state "$F")"; ok "nginx started" ;;

  edge-filtered:inject) pf_block_port "$HTTPS_PORT"; touch "$(state "$F")"; ok "pf now drops :$HTTPS_PORT" ;;
  edge-filtered:undo)   pf_unblock; rm -f "$(state "$F")"; ok "pf fault rule removed" ;;

  backend-filtered:inject)
    case "$(my_ip)" in "$BACKEND_A_IP") p="$BACKEND_A_PORT";; "$BACKEND_B_IP") p="$BACKEND_B_PORT";; *) die "Run on Mac 3 or Mac 4";; esac
    pf_block_port "$p"; touch "$(state "$F")"; ok "pf now drops :$p — even from the edge" ;;
  backend-filtered:undo) pf_unblock; rm -f "$(state "$F")"; ok "pf fault rule removed" ;;

  *) list; die "Unknown fault/mode: $F $MODE" ;;
esac

[[ "$MODE" == inject ]] && warn "Fault injected. Undo with:  make p2-fault-undo F=$F" || ok "Restored."
