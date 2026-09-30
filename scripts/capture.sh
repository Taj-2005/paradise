#!/usr/bin/env bash
# Packet capture helper — spec Task G, form fields C1/C2/C3.
#
#   ./scripts/capture.sh dns      # UDP/53 only
#   ./scripts/capture.sh tcp      # handshake to the edge
#   ./scripts/capture.sh tls      # the HTTPS conversation
#   ./scripts/capture.sh full     # everything for one request (recommended)
#
# Writes to evidence/captures/. Open the .pcapng in Wireshark afterwards and
# apply the display filter the script prints.
#
# Captures are deliberately FILTERED at capture time. An unfiltered capture on
# a busy Wi-Fi network is hundreds of megabytes of other people's traffic, and
# finding your three interesting packets in it wastes demo time.

source "$(dirname "$0")/lib/common.sh"
load_env

MODE="${1:-full}"
OUT="$REPO_ROOT/evidence/captures"
mkdir -p "$OUT"

need_cmd tcpdump

case "$MODE" in
  dns)  FILTER="udp port 53"
        DISPLAY="dns"
        DESC="DNS queries and responses" ;;
  tcp)  FILTER="tcp port $HTTPS_PORT"
        DISPLAY="tcp.flags.syn==1"
        DESC="TCP handshake to the edge" ;;
  tls)  FILTER="tcp port $HTTPS_PORT"
        DISPLAY="tls"
        DESC="TLS handshake and application data" ;;
  full) FILTER="udp port 53 or tcp port $HTTPS_PORT"
        DISPLAY="dns || tcp.flags.syn==1 || tls"
        DESC="the complete DNS -> TCP -> TLS flow" ;;
  *)    die "Unknown mode '$MODE'. Use: dns | tcp | tls | full" ;;
esac

# No Date.now() in the shell either — use a counter so filenames stay unique
# without depending on the clock being set correctly.
n=1
while [[ -e "$OUT/$MODE-$n.pcapng" ]]; do n=$((n+1)); done
FILE="$OUT/$MODE-$n.pcapng"

hdr "Capturing $DESC"
printf '  interface      %s\n' "$IFACE"
printf '  capture filter %s\n' "$FILTER"
printf '  output         %s\n' "${FILE#"$REPO_ROOT"/}"
echo

cat <<INSTRUCTIONS
  ${C_BLD}In a SECOND terminal, generate the traffic:${C_OFF}

      sudo dscacheutil -flushcache          # force a real DNS query
      curl -v $APP_URL/api/status

  Then come back here and press ${C_BLD}Ctrl-C${C_OFF} to stop the capture.

INSTRUCTIONS

# -s0 full packets, -w write raw. Needs sudo for promiscuous access.
sudo tcpdump -i "$IFACE" -s0 -w "$FILE" "$FILTER" || true

echo
if [[ -f "$FILE" ]]; then
  sudo chown "$(id -un)" "$FILE" 2>/dev/null || true
  ok "Saved $(du -h "$FILE" | cut -f1) -> ${FILE#"$REPO_ROOT"/}"
  cat <<NEXT

  ${C_BLD}Open it:${C_OFF}
      open -a Wireshark "$FILE"

  ${C_BLD}Display filter to apply:${C_OFF}
      $DISPLAY

  ${C_BLD}What to look for and write down${C_OFF} (form C1/C2/C3 want specifics,
  not "we saw packets" — vague answers score 0-1):

    DNS   Standard query A $APP_DOMAIN
          from <your ip> to $DNS_IP port 53 (UDP)
          Response ANSWER SECTION: $APP_DOMAIN A $EDGE_IP, TTL $DNS_TTL

    TCP   SYN     <your ip>:<ephemeral> -> $EDGE_IP:$HTTPS_PORT
          SYN-ACK $EDGE_IP:$HTTPS_PORT -> <your ip>:<ephemeral>
          ACK     connection established, Seq=0 Ack=1
          Note that this completes BEFORE any TLS byte is sent.

    TLS   ClientHello  (TLS version + cipher suites offered)
          ServerHello + Certificate  (the edge presents its cert)
          ChangeCipherSpec, then only "Application Data"
          The HTTP request and response are inside those encrypted records,
          which is exactly why you cannot read the headers in Wireshark.

NEXT
else
  err "No capture file was written."
fi
