#!/usr/bin/env bash
# [client]  Extension F — systematic, top-down diagnosis. Say each line aloud.
#
#   0 local    what does THIS machine believe? (resolvers, /etc/hosts override)
#   1 DNS      does the name resolve, who answered, is the answer a real edge?
#   2 network  is that IP reachable at all? (ICMP)
#   3 TCP      does anything accept a connection on :$HTTPS_PORT? refused vs timeout
#   4 TLS      does the handshake complete and the certificate verify?
#   5 HTTP     what did the application say? 200 / 502 / 504 …
#
# The FIRST layer that fails names the fault; every layer below it is proven
# fine. Later layers still run, so you see the full picture — but the verdict
# is the first failure, because the rest are usually its consequences.

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

ev_open "F-troubleshooting/F-diagnose-$(date +%Y%m%d-%H%M%S).txt" "Extension F — layer-by-layer diagnosis"
hdr "Diagnose $APP_URL from $(my_ip)"

VERDICT=""; HINT=""
pass_l() { ev_note "  ${C_GRN}✓${C_OFF} $*"; }
fail_l() { # fail_l <layer> <what> <hint>
  ev_note "  ${C_RED}✗${C_OFF} $2"
  if [[ -z "$VERDICT" ]]; then VERDICT="$1"; HINT="$3"; fi
}
info_l() { ev_note "  ${C_DIM}·${C_OFF} $*"; }

# ── 0 · local ────────────────────────────────────────────────────────────────
step "0 · Local configuration"
res="$(networksetup -getdnsservers "$NET_SERVICE" 2>/dev/null | tr '\n' ' ')"
info_l "resolvers ($NET_SERVICE): $res"
case "$res" in
  *"$DNS_IP"*|*"$BACKUP_DNS_IP"*) pass_l "resolver list includes the team DNS" ;;
  *) fail_l "DNS (client resolver config)" "resolver list does not include $DNS_IP or $BACKUP_DNS_IP" \
        "Client is asking the wrong DNS server. Fix: make p2-client-dns" ;;
esac
hosts_line="$(grep -E "^[^#]*[[:space:]]$APP_DOMAIN([[:space:]]|\$)" /etc/hosts 2>/dev/null || true)"
if [[ -n "$hosts_line" ]]; then
  fail_l "DNS (local /etc/hosts override)" "/etc/hosts overrides the name: $hosts_line" \
    "/etc/hosts is consulted BEFORE DNS. Remove the line (sudo vi /etc/hosts), then make p2-flush"
else pass_l "/etc/hosts has no override for $APP_DOMAIN"; fi

# ── 1 · DNS ──────────────────────────────────────────────────────────────────
step "1 · DNS — does the name resolve, and to what?"
for s in "$DNS_IP" "$BACKUP_DNS_IP"; do
  a="$(dig_a "$s" "$APP_DOMAIN")"
  [[ -n "$a" ]] && info_l "@$s answers $a (TTL $(dig_ttl "$s" "$APP_DOMAIN")s)" || info_l "@$s: no answer (service down or unreachable)"
done
dig_ans="$(dig +short +time=2 +tries=1 "$APP_DOMAIN" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)"
dig_srv="$(dig +time=2 +tries=1 "$APP_DOMAIN" 2>/dev/null | awk '/^;; SERVER:/{print $3}' || true)"
os_ans="$(os_cache_ip "$APP_DOMAIN")"
info_l "dig (asks the server):        ${dig_ans:-<none>}   SERVER: ${dig_srv:-<none>}"
info_l "OS resolver (what apps use):  ${os_ans:-<none>}"
IP="${os_ans:-$dig_ans}"
if [[ -z "$IP" ]]; then
  fail_l "DNS (resolution)" "name does not resolve" \
    "No resolver answered. dig @$DNS_IP and @$BACKUP_DNS_IP directly; on the DNS Macs: make p2-dns-start / make p2-status"
elif [[ "$IP" != "$EDGE_IP" && "$IP" != "$STANDBY_EDGE_IP" ]]; then
  fail_l "DNS (wrong record)" "resolves to $IP, which is neither edge ($EDGE_IP / $STANDBY_EDGE_IP)" \
    "Resolution 'works' but sends clients to the wrong host — DNS is a directory, not a connection. On Mac 1: make p2-cutover TO=primary"
else
  pass_l "$APP_DOMAIN -> $IP  ($(edge_label "$IP"))"
  [[ -n "$dig_ans" && -n "$os_ans" && "$dig_ans" != "$os_ans" ]] && \
    info_l "${C_YEL}dig and the OS disagree — the OS is serving a cached answer (TTL) — make p2-flush${C_OFF}"
fi

# ── 2 · network ──────────────────────────────────────────────────────────────
step "2 · Network — is $IP reachable?"
if [[ -n "$IP" ]]; then
  if ping -c2 -t3 "$IP" >/dev/null 2>&1; then pass_l "ping $IP ok"
  else fail_l "Network (IP reachability)" "ping $IP fails" \
         "Host down, off the LAN, or wrong IP. Check Wi-Fi, ipconfig getifaddr $IFACE on that Mac, make preflight"; fi
else info_l "skipped — no IP"; fi

# ── 3 · TCP ──────────────────────────────────────────────────────────────────
step "3 · Transport — TCP connect to $IP:$HTTPS_PORT"
if [[ -n "$IP" ]]; then
  rc=0; nc_out="$(nc -vz -G 3 "$IP" "$HTTPS_PORT" 2>&1)" || rc=$?
  if (( rc == 0 )); then pass_l "TCP handshake to :$HTTPS_PORT completes"
  elif [[ "$nc_out" == *refused* ]]; then
    fail_l "Transport (port closed)" "connection REFUSED on :$HTTPS_PORT (RST)" \
      "Host is up but nothing listens on :$HTTPS_PORT — nginx stopped or on another port. On the edge: sudo lsof -nP -iTCP:$HTTPS_PORT -sTCP:LISTEN; sudo nginx"
  else
    fail_l "Transport (filtered)" "connection TIMED OUT on :$HTTPS_PORT (no SYN-ACK, no RST)" \
      "Silently dropped — a firewall. On the edge: sudo pfctl -sr; sudo pfctl -a 'com.apple/*' -sr"
  fi
else info_l "skipped — no IP"; fi

# ── 4 · TLS + 5 · HTTP ──────────────────────────────────────────────────────
step "4 · TLS — handshake and certificate (no -k, ever)"
rc=0; v="$(curl -sv --connect-timeout 3 --max-time 6 -o /dev/null "$APP_URL/api/status" 2>&1)" || rc=$?
case "$rc" in
  0)  pass_l "$(printf '%s' "$v" | grep -m1 -E 'SSL connection using' | sed 's/^\* //')"
      pass_l "certificate verified for $APP_DOMAIN" ;;
  60|77) fail_l "TLS (trust)" "certificate NOT trusted (curl $rc)" \
           "This Mac does not trust the issuing CA, or the edge serves a different cert. make client-trust; never -k" ;;
  51) fail_l "TLS (name)" "certificate name does not match $APP_DOMAIN" "SAN mismatch — regenerate the cert with the right SAN" ;;
  35) fail_l "TLS (handshake)" "TLS handshake failed (curl 35)" "Protocol/cipher mismatch or wrong service on :$HTTPS_PORT" ;;
  6)  info_l "curl could not resolve the host (already explained at layer 1)" ;;
  7|28) info_l "curl could not connect (already explained at layer 3)" ;;
  *)  fail_l "TLS/HTTP" "curl exit $rc" "$(printf '%s' "$v" | grep -m1 -iE 'error|fail' || true)" ;;
esac

step "5 · HTTP — what did the application say?"
one_request "$APP_URL/api/status"
case "$REQ_CODE" in
  200) pass_l "HTTP 200  X-Backend: ${REQ_BACKEND:-?}  X-Edge: ${REQ_EDGE:-?}" ;;
  502|504) fail_l "Application (upstream)" "HTTP $REQ_CODE from ${REQ_EDGE:-the edge} — edge is fine, backends are not" \
        "DNS, TCP and TLS all worked: the edge ends here. From Mac 2: curl http://$BACKEND_A_IP:$BACKEND_A_PORT/healthz and :$BACKEND_B_PORT. Running? Bound to 0.0.0.0? pf allow-list includes the edge?" ;;
  000) info_l "no HTTP response (see the layer above)" ;;
  *) fail_l "Application" "HTTP $REQ_CODE" "Read the body: curl -i $APP_URL/api/status" ;;
esac

echo
if [[ -z "$VERDICT" ]]; then
  ev_note "${C_GRN}${C_BLD}VERDICT: healthy — every layer passes.${C_OFF}"
else
  ev_note "${C_RED}${C_BLD}VERDICT: first failing layer = $VERDICT${C_OFF}"
  ev_note "  → $HINT"
fi
ev_close
