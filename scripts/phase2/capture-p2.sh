#!/usr/bin/env bash
# [any]  Phase 2 packet-capture helper (Wireshark evidence for Ext A-E).
#
#   ./scripts/phase2/capture-p2.sh dns        # Ext A, B, E : UDP/53
#   ./scripts/phase2/capture-p2.sh isolation  # Ext C       : backend ports
#   ./scripts/phase2/capture-p2.sh ha         # Ext D       : backend ports (watch RSTs)
#   ./scripts/phase2/capture-p2.sh cutover    # Ext E       : DNS + TLS to either edge
#
# Writes evidence/captures/p2-<mode>-<n>.pcapng (gitignored) and prints the
# trigger commands and the Wireshark display filter for that mode.

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env
need_cmd tcpdump

MODE="${1:-}"
BP="$BACKEND_A_PORT"; BQ="$BACKEND_B_PORT"

case "$MODE" in
  dns)       FILTER="udp port 53"
             DISPLAY='dns.qry.name == "'"$APP_DOMAIN"'"'
             WHO="run on a CLIENT"
             TRIGGER="Ext A: 'make p2-dns-stop' on Mac 1, then here: sudo dscacheutil -flushcache; dig $APP_DOMAIN
      Ext B: 'make p2-ttl-watch' here while Mac 1+4 run 'make p2-cutover TO=standby'"
             SHOT="Ext A: queries to Mac 1 with 'no response seen', then Mac 4 answered.
      Ext B: add dns.resp.ttl as a column; TTL ${P2_DNS_TTL}; A record changes at cutover." ;;
  isolation) FILTER="tcp port $BP or tcp port $BQ"
             DISPLAY="tcp.port == $BP || tcp.port == $BQ"
             WHO="run on a CLIENT (blocked view) and again on Mac 3/4 or Mac 2 (allowed view)"
             TRIGGER="client: curl --connect-timeout 5 http://$BACKEND_A_IP:$BP/healthz
      Mac 2 : curl http://$BACKEND_A_IP:$BP/healthz"
             SHOT="Blocked: SYN + retransmissions (tcp.analysis.retransmission), NO SYN-ACK, NO RST = FILTERED.
      Allowed: SYN, SYN-ACK, ACK, HTTP." ;;
  ha)        FILTER="tcp port $BP or tcp port $BQ"
             DISPLAY="tcp.flags.reset == 1 && tcp.srcport == $BP"
             WHO="run on Mac 2 (the edge)"
             TRIGGER="client: make p2-ha-demo ; Ctrl-C Backend A at ~10s, 'make backend-a' at ~35s"
             SHOT="RST from Backend A once it stops, then every request going to Backend B." ;;
  cutover)   FILTER="udp port 53 or tcp port $HTTPS_PORT"
             DISPLAY='dns.flags.response == 1 || (tls.handshake.type == 1 && (ip.dst == '"$EDGE_IP"' || ip.dst == '"$STANDBY_EDGE_IP"'))'
             WHO="run on a CLIENT"
             TRIGGER="here: make p2-ttl-watch ; Mac 1+4: make p2-cutover TO=standby ; here: make p2-flush"
             SHOT="DNS answer changes edge -> standby; later ClientHello (see SNI) goes to $STANDBY_EDGE_IP." ;;
  *)         die "Usage: capture-p2.sh dns | isolation | ha | cutover" ;;
esac

OUT="$REPO_ROOT/evidence/captures"; mkdir -p "$OUT"
n=1; while [[ -e "$OUT/p2-$MODE-$n.pcapng" ]]; do n=$((n+1)); done
FILE="$OUT/p2-$MODE-$n.pcapng"

hdr "Phase 2 capture: $MODE"
printf '  %s\n  interface      %s\n  capture filter %s\n  output         %s\n\n' \
  "$WHO" "$IFACE" "$FILTER" "${FILE#"$REPO_ROOT"/}"
printf '  Trigger (second terminal):\n      %s\n\n  Ctrl-C here when done.\n\n' "$TRIGGER"

sudo tcpdump -i "$IFACE" -s0 -w "$FILE" "$FILTER" || true

echo
if [[ -s "$FILE" ]]; then
  sudo chown "$(id -un)" "$FILE" 2>/dev/null || true
  ok "Saved $(du -h "$FILE" | cut -f1) -> ${FILE#"$REPO_ROOT"/}"
  printf '\n  open -a Wireshark "%s"\n  Display filter: %s\n  Screenshot:     %s\n' "$FILE" "$DISPLAY" "$SHOT"
  echo "  Save as evidence/phase2/screenshots/<Ext>-<n>-<what>.png"
else
  err "No capture file was written."
fi
