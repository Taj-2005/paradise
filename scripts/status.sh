#!/usr/bin/env bash
# What is running on THIS machine, and can it see the others?
# First thing to run when something is wrong.

source "$(dirname "$0")/lib/common.sh"
load_env

hdr "Machine status — $(hostname -s)"

MY_IP="$(my_ip)"
ROLE="$(my_role)"
printf '  IP        %s (%s)\n' "${MY_IP:-<none>}" "$IFACE"
printf '  Role      %s\n' "$ROLE"
printf '  Team      %s  (%s)\n' "$TEAM" "$APP_DOMAIN"
[[ "$ROLE" == "unknown" ]] && warn "This IP is not in .env — update DNS_IP/EDGE_IP/BACKEND_*_IP"

step "Services on this machine"
for spec in "dnsmasq:53:DNS" "nginx:$HTTPS_PORT:Edge HTTPS" "nginx:$HTTP_PORT:Edge HTTP" \
            "node:$BACKEND_A_PORT:Backend A" "node:$BACKEND_B_PORT:Backend B"; do
  IFS=: read -r proc port label <<< "$spec"
  found="$(sudo lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -i "$proc" | head -1)"
  if [[ -n "$found" ]]; then
    bind="$(printf '%s' "$found" | awk '{print $9}')"
    # A loopback-only bind is the silent killer; call it out explicitly.
    if [[ "$bind" == 127.0.0.1:* || "$bind" == localhost:* ]]; then
      err "$label on :$port — bound to LOOPBACK ONLY ($bind). Other machines cannot reach it."
    else
      ok "$label on :$port ($bind)"
    fi
  else
    printf '  %s·%s %s on :%s — not running here\n' "$C_DIM" "$C_OFF" "$label" "$port"
  fi
done

step "Reachability to the other machines"
for spec in "Mac1 DNS:$DNS_IP" "Mac2 Edge:$EDGE_IP" "Mac3 A:$BACKEND_A_IP" "Mac4 B:$BACKEND_B_IP"; do
  IFS=: read -r label ip <<< "$spec"
  if [[ "$ip" == "$MY_IP" ]]; then
    printf '  %s·%s %-12s %-15s (this machine)\n' "$C_DIM" "$C_OFF" "$label" "$ip"
  elif ping -c1 -W1000 "$ip" >/dev/null 2>&1; then
    ok "$(printf '%-12s %-15s reachable' "$label" "$ip")"
  else
    err "$(printf '%-12s %-15s NO RESPONSE' "$label" "$ip")"
  fi
done

step "Name resolution from here"
srv="$(dig "$APP_DOMAIN" 2>/dev/null | awk '/^;; SERVER:/{print $3}')"
ans="$(dig +short "$APP_DOMAIN" 2>/dev/null | head -1)"
printf '  resolver  %s\n' "${srv:-<none>}"
printf '  %s -> %s\n' "$APP_DOMAIN" "${ans:-<no answer>}"
if [[ "$ans" == "$EDGE_IP" ]]; then ok "Resolves correctly"
elif [[ -z "$ans" ]]; then err "No answer — is this machine pointed at $DNS_IP? Run: make client-dns"
else err "Wrong answer (expected $EDGE_IP)"; fi

step "Service reachable end to end"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$APP_URL/api/status" 2>/dev/null || echo 000)"
case "$code" in
  200) ok "$APP_URL/api/status -> 200" ;;
  000) err "$APP_URL -> connection failed (DNS, firewall, or nginx down)" ;;
  502) err "$APP_URL -> 502: edge is up, both backends unreachable" ;;
  *)   warn "$APP_URL -> HTTP $code" ;;
esac
echo
