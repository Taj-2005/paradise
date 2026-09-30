#!/usr/bin/env bash
# Collect every piece of terminal evidence the form asks for, into evidence/.
# Run from a CLIENT machine (Mac 1, 3 or 4 — NOT Mac 2; field A3 requires it).
#
#   ./scripts/collect-evidence.sh
#
# What it does NOT do: invent output. Wireshark descriptions (C1-C3) and the
# failure demo (D3) need a human; this script writes templates for those with
# the exact commands and a <<< PASTE >>> marker.

source "$(dirname "$0")/lib/common.sh"
load_env

E="$REPO_ROOT/evidence"
mkdir -p "$E"/{A-lan-dns,B-https-lb,C-wireshark,D-cache-fail,captures}

hdr "Collecting Phase 1 evidence — $TEAM"

if [[ "$(my_role)" == "mac2-edge" ]]; then
  err "You are on the EDGE machine."
  die "Form field A3 requires dig output from a CLIENT. Run this on Mac 1, 3 or 4."
fi

# Header block written at the top of each file so the evaluator always knows
# which machine produced the output and when.
stamp() {
  printf '# %s\n# machine: %s (%s, role=%s)\n# command: %s\n# ------------------------------------------------------------------\n\n' \
    "$1" "$(hostname -s)" "$(my_ip)" "$(my_role)" "$2"
}

# ════════ A1 ══════════════════════════════════════════════════════════════
info "A1 — machine IPs and roles"
{
  stamp "A1: Machine IPs, roles and interfaces" "ifconfig / ipconfig"
  printf '%-22s %-16s %-6s %s\n' "ROLE" "PRIVATE IPv4" "IFACE" "NOTE"
  printf '%-22s %-16s %-6s %s\n' "Mac 1 / DNS server"  "$DNS_IP"       "$IFACE" "dnsmasq, test client"
  printf '%-22s %-16s %-6s %s\n' "Mac 2 / Edge nginx"  "$EDGE_IP"      "$IFACE" "TLS termination, load balancer"
  printf '%-22s %-16s %-6s %s\n' "Mac 3 / Backend A"   "$BACKEND_A_IP" "$IFACE" "port $BACKEND_A_PORT"
  printf '%-22s %-16s %-6s %s\n' "Mac 4 / Backend B"   "$BACKEND_B_IP" "$IFACE" "port $BACKEND_B_PORT, test client"
  echo
  echo "--- full detail for THIS machine ($(hostname -s)) ---"
  echo "\$ ipconfig getifaddr $IFACE"
  ipconfig getifaddr "$IFACE"
  echo
  echo "\$ ifconfig $IFACE"
  ifconfig "$IFACE"
  echo
  echo "\$ route -n get default | grep gateway"
  route -n get default 2>/dev/null | awk '/gateway:/{print}'
  echo
  echo "NOTE: run this script on all four Macs and merge the per-machine"
  echo "sections, so every machine's real interface detail is captured."
} > "$E/A-lan-dns/A1-ips.txt"

# ════════ A3 ══════════════════════════════════════════════════════════════
info "A3 — dig from this client"
{
  stamp "A3: dig $APP_DOMAIN from a CLIENT machine" "dig $APP_DOMAIN"
  dig "$APP_DOMAIN"
  echo
  echo "=================================================================="
  echo "Evaluator checks:"
  echo "  ANSWER SECTION shows the edge IP    -> expecting $EDGE_IP"
  echo "  SERVER line shows OUR DNS server    -> expecting $DNS_IP"
  echo "=================================================================="
  echo
  echo "\$ dig $API_DOMAIN"
  dig "$API_DOMAIN"
} > "$E/A-lan-dns/A3-dig-client.txt"

# ════════ A4 ══════════════════════════════════════════════════════════════
info "A4 — dig @8.8.8.8 (expect NXDOMAIN)"
{
  stamp "A4: dig @8.8.8.8 $APP_DOMAIN — proves the name is private" "dig @8.8.8.8 $APP_DOMAIN"
  dig @8.8.8.8 "$APP_DOMAIN" 2>&1 || echo "(timed out — also an acceptable result)"
} > "$E/A-lan-dns/A4-dig-8888.txt"

# ════════ A5 ══════════════════════════════════════════════════════════════
info "A5 — ping matrix from this machine"
{
  stamp "A5: ping from $(hostname -s) to every other machine" "ping -c4 <ip>"
  for spec in "Mac1 DNS:$DNS_IP" "Mac2 Edge:$EDGE_IP" "Mac3 BackendA:$BACKEND_A_IP" "Mac4 BackendB:$BACKEND_B_IP"; do
    IFS=: read -r label ip <<< "$spec"
    [[ "$ip" == "$(my_ip)" ]] && continue
    echo "\$ ping -c4 $ip        # -> $label"
    ping -c4 -W1000 "$ip" 2>&1 || true
    echo
  done
  echo "NOTE: the form wants EVERY pair. Run this on all four Macs and"
  echo "concatenate, or summarise as:  Mac1 -> Mac2: 0% loss, etc."
} > "$E/A-lan-dns/A5-ping-matrix.txt"

# ════════ B1 ══════════════════════════════════════════════════════════════
info "B1 — curl -v over HTTPS (no -k)"
{
  stamp "B1: curl -v $APP_URL — NO -k FLAG" "curl -v $APP_URL/api/status"
  curl -v "$APP_URL/api/status" 2>&1 || true
  echo
  echo "=================================================================="
  echo "Evaluator checks: TLS handshake lines, certificate subject matching"
  echo "the domain, HTTP 200, no -k anywhere, domain name not an IP."
  echo "=================================================================="
} > "$E/B-https-lb/B1-curl-verbose.txt"

if grep -qi 'verification SKIPPED\|insecure' "$E/B-https-lb/B1-curl-verbose.txt"; then
  err "B1 output mentions skipped verification — DO NOT SUBMIT THIS."
  err "Fix trust first:  make client-trust"
fi

# ════════ B2 ══════════════════════════════════════════════════════════════
info "B2 — 6 consecutive requests"
{
  stamp "B2: load-balancing proof, 6 consecutive requests" \
        "for i in {1..6}; do curl -s $APP_URL/api/status; echo; done"
  for i in 1 2 3 4 5 6; do
    echo "--- request $i ---"
    curl -s -D - "$APP_URL/api/status" 2>&1 | grep -iE '^HTTP|^x-backend|^\{' || true
    echo
  done
  echo "=================================================================="
  echo "Both X-Backend: A and X-Backend: B must appear above."
  echo "=================================================================="
} > "$E/B-https-lb/B2-lb-6x.txt"

# ════════ B3 ══════════════════════════════════════════════════════════════
info "B3 — nginx configuration"
{
  stamp "B3: nginx configuration (upstream + server blocks)" "cat conf.d/site.conf"
  if [[ -f "$REPO_ROOT/infra/mac2-edge/nginx/conf.d/site.conf" ]]; then
    cat "$REPO_ROOT/infra/mac2-edge/nginx/conf.d/site.conf"
  else
    echo "<<< Run ./scripts/render-configs.sh, or copy from Mac 2:"
    echo "<<<   cat $BREW_PREFIX/etc/nginx/conf.d/site.conf"
  fi
} > "$E/B-https-lb/B3-nginx.conf"

# ════════ D1 ══════════════════════════════════════════════════════════════
info "D1 — caching headers"
{
  stamp "D1: HTTP caching headers" "curl -sI $APP_URL/api/status"
  echo "\$ curl -sI $APP_URL/api/status"
  curl -sI "$APP_URL/api/status" 2>&1 || true
  echo
  echo "--- conditional request demo, on /api/cacheable ---"
  echo "# /api/status embeds the backend id in its body, so its ETag differs"
  echo "# per replica; with round-robin the 304 would be intermittent."
  echo "# /api/cacheable has a byte-identical body on both backends."
  echo
  echo "\$ curl -sI $APP_URL/api/cacheable"
  curl -sI "$APP_URL/api/cacheable" 2>&1 || true
  ETAG="$(curl -sI "$APP_URL/api/cacheable" | awk -F': ' 'tolower($1)=="etag"{gsub(/\r/,"");print $2}' | head -1)"
  echo
  echo "\$ curl -sI -H 'If-None-Match: $ETAG' $APP_URL/api/cacheable"
  curl -sI -H "If-None-Match: $ETAG" "$APP_URL/api/cacheable" 2>&1 || true
  echo
  echo "--- contrast: an endpoint that must not be cached ---"
  echo "\$ curl -sI $APP_URL/api/time"
  curl -sI "$APP_URL/api/time" 2>&1 || true
} > "$E/D-cache-fail/D1-headers.txt"

# ════════ Templates that need a human ════════════════════════════════════
for spec in "C1-dns:dns:DNS query and response" \
            "C2-tcp:tcp.flags.syn==1:TCP three-way handshake" \
            "C3-tls:tls:TLS handshake"; do
  IFS=: read -r name filter desc <<< "$spec"
  f="$E/C-wireshark/$name.md"
  [[ -f "$f" ]] && continue
  {
    echo "# $desc"
    echo
    echo "**Wireshark display filter:** \`$filter\`"
    echo
    echo "Capture with: \`./scripts/capture.sh ${name#C?-}\`"
    echo
    echo "> Vague descriptions score 0-1. Name specific IPs, ports, packet"
    echo "> types, and say what each one proves."
    echo
    echo '```'
    echo "<<< PASTE YOUR DESCRIPTION HERE >>>"
    echo '```'
  } > "$f"
done
info "C1-C3 templates written (these need you to watch the capture)"

# ════════ Summary ═════════════════════════════════════════════════════════
echo
step "Collected"
find "$E" -type f \( -name '*.txt' -o -name '*.conf' -o -name '*.md' \) \
  | sort | sed "s|$E/|    |"

cat <<NEXT

  ${C_BLD}Still needs a human:${C_OFF}
    C1 C2 C3   ./scripts/capture.sh full   then describe what you see
    D2         write the Cache-Control explanation in your own words
    D3         ./scripts/failure-demo.sh   (writes its own evidence file)

  Then paste each file into its form field. ${C_BLD}evidence/README.md${C_OFF}
  maps every field to the file that answers it.

NEXT
