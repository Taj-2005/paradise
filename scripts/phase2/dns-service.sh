#!/usr/bin/env bash
# [Mac 1 or backup DNS]  Stop / start / show dnsmasq — for the Ext A failover demo.
#   ./dns-service.sh stop|start|status

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

case "${1:-status}" in
  stop)
    hdr "Stopping dnsmasq on $(my_ip)"
    dnsmasq_stop
    dnsmasq_running && die "dnsmasq is still running" || ok "dnsmasq stopped — UDP/53 on $(my_ip) now answers ICMP port-unreachable"
    ;;
  start)
    hdr "Starting dnsmasq on $(my_ip)"
    dnsmasq_restart
    ;;
  status)
    if dnsmasq_running; then ok "dnsmasq running (pid $(pgrep -x dnsmasq | tr '\n' ' '))"
    else warn "dnsmasq NOT running"; fi
    sudo lsof -nP -iUDP:53 2>/dev/null | sed 's/^/    /' || true
    ;;
  *) die "Usage: $(basename "$0") stop|start|status" ;;
esac
