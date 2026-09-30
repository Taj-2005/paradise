#!/usr/bin/env bash
# Run this FIRST, on any machine, before touching anything else.
# Spec Task A: verify reachability between every pair of machines.
#
# It checks what THIS machine can see. Run it on all four and you have covered
# every pair — which is exactly what form field A5 asks you to paste.

source "$(dirname "$0")/lib/common.sh"
load_env

hdr "Preflight — $(hostname -s) ($(my_ip))"

MY_IP="$(my_ip)"
[[ -n "$MY_IP" ]] || die "No IP on interface $IFACE. Is Wi-Fi connected? Check IFACE in .env."

step "1. This machine"
printf '  hostname   %s\n' "$(hostname -s)"
printf '  interface  %s\n' "$IFACE"
printf '  IPv4       %s\n' "$MY_IP"
printf '  netmask    %s\n' "$(ipconfig getoption "$IFACE" subnet_mask 2>/dev/null || echo '?')"
printf '  gateway    %s\n' "$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')"
printf '  MAC        %s\n' "$(ifconfig "$IFACE" 2>/dev/null | awk '/ether/{print $2}')"
printf '  role       %s\n' "$(my_role)"

# Everyone must be on the same /24 for the flat-LAN assumption to hold.
step "2. Same subnet?"
prefix() { printf '%s' "$1" | cut -d. -f1-3; }
mine="$(prefix "$MY_IP")"
for spec in "Mac1:$DNS_IP" "Mac2:$EDGE_IP" "Mac3:$BACKEND_A_IP" "Mac4:$BACKEND_B_IP"; do
  IFS=: read -r label ip <<< "$spec"
  if [[ "$(prefix "$ip")" == "$mine" ]]; then ok "$label $ip"
  else warn "$label $ip is on a different /24 than this machine ($mine.x)"; fi
done

step "3. Ping every other machine (spec A5)"
for spec in "Mac1 DNS:$DNS_IP" "Mac2 Edge:$EDGE_IP" "Mac3 BackendA:$BACKEND_A_IP" "Mac4 BackendB:$BACKEND_B_IP"; do
  IFS=: read -r label ip <<< "$spec"
  [[ "$ip" == "$MY_IP" ]] && { printf '  %s·%s %-16s %-15s (self)\n' "$C_DIM" "$C_OFF" "$label" "$ip"; continue; }
  out="$(ping -c4 -W1000 "$ip" 2>&1 || true)"
  loss="$(printf '%s' "$out" | awk -F', ' '/packet loss/{print $3}')"
  rtt="$(printf '%s' "$out" | awk -F'/' '/round-trip/{printf "avg %.1fms", $5}')"
  if printf '%s' "$loss" | grep -q '^0.0%'; then
    ok "$(printf '%-16s %-15s %s  %s' "$label" "$ip" "$loss" "$rtt")"
  else
    err "$(printf '%-16s %-15s %s' "$label" "$ip" "${loss:-unreachable}")"
  fi
done

step "4. Service ports"
for spec in "DNS/53:$DNS_IP:53:udp" "Edge/$HTTPS_PORT:$EDGE_IP:$HTTPS_PORT:tcp" \
            "BackendA:$BACKEND_A_IP:$BACKEND_A_PORT:tcp" "BackendB:$BACKEND_B_IP:$BACKEND_B_PORT:tcp"; do
  IFS=: read -r label ip port proto <<< "$spec"
  if [[ "$proto" == udp ]]; then
    # A UDP port cannot be probed by connecting; ask it a real question.
    if dig +short +time=2 +tries=1 "@$ip" "$APP_DOMAIN" >/dev/null 2>&1 \
       && [[ -n "$(dig +short +time=2 +tries=1 "@$ip" "$APP_DOMAIN")" ]]; then
      ok "$(printf '%-12s %s:%s answers DNS queries' "$label" "$ip" "$port")"
    else
      err "$(printf '%-12s %s:%s no DNS answer' "$label" "$ip" "$port")"
    fi
  else
    if nc -z -G2 "$ip" "$port" >/dev/null 2>&1; then
      ok "$(printf '%-12s %s:%s open' "$label" "$ip" "$port")"
    else
      err "$(printf '%-12s %s:%s closed or filtered' "$label" "$ip" "$port")"
    fi
  fi
done

step "5. Required tooling on this machine"
for spec in "curl:curl" "dig:bind" "nc:netcat" "node:node" "npm:node"; do
  IFS=: read -r cmd pkg <<< "$spec"
  command -v "$cmd" >/dev/null 2>&1 && ok "$cmd" || err "$cmd missing — brew install $pkg"
done
for spec in "dnsmasq:mac1-dns" "nginx:mac2-edge"; do
  IFS=: read -r cmd role <<< "$spec"
  if [[ "$(my_role)" == "$role" ]]; then
    command -v "$cmd" >/dev/null 2>&1 && ok "$cmd (required on this machine)" \
      || err "$cmd missing — brew install $cmd"
  fi
done

echo
info "Run this on all four Macs — together they cover every pair for form field A5."
echo
