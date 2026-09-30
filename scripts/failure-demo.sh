#!/usr/bin/env bash
# Controlled failure demonstrations — spec §6.3, form field D3.
#
#   ./scripts/failure-demo.sh          # interactive menu
#   ./scripts/failure-demo.sh A        # run one directly
#
# Each demo captures BEFORE state, performs the break, captures AFTER state,
# names the affected layer, and restores. All four of those are marked.
#
# Option A is the one to record for the video: it is visual, fast, and
# recovers cleanly on camera.

source "$(dirname "$0")/lib/common.sh"
load_env

OUT="$REPO_ROOT/evidence/D-cache-fail"
mkdir -p "$OUT"

backends_seen() {
  local n="${1:-6}" out=""
  for _ in $(seq 1 "$n"); do
    out="$out$(curl -s -D - -o /dev/null --max-time 5 "$APP_URL/api/status" 2>/dev/null \
      | awk -F': ' 'tolower($1)=="x-backend"{gsub(/\r/,"");printf "%s",$2}')"
  done
  printf '%s' "${out:-<no responses>}"
}

http_codes() {
  local n="${1:-6}" out=""
  for _ in $(seq 1 "$n"); do
    out="$out$(curl -s -o /dev/null -w '%{http_code} ' --max-time 5 "$APP_URL/api/status" 2>/dev/null || printf '000 ')"
  done
  printf '%s' "$out"
}

# ─────────────────────────────────────────────────────────────────────────
demo_A() {
  hdr "Option A — stop one backend"
  cat <<'WHY'
  What this proves: the load balancer removes a failed target from rotation
  and the service keeps serving. The failure is at the APPLICATION layer —
  DNS still resolves, TCP to the edge still connects, TLS still completes.
  Only the upstream pool changed.

WHY

  step "BEFORE"
  local before; before="$(backends_seen 6)"
  info "six requests served by: $before"
  [[ "$before" == *A* && "$before" == *B* ]] \
    || { err "Both backends must be up before you can demo one failing."; return 1; }
  ok "both backends in rotation"

  echo
  warn "Now go to Mac 3 and press Ctrl-C on the Backend A process."
  warn "(Or from here: ssh $BACKEND_A_IP 'pkill -f \"BACKEND_ID=A\"')"
  read -rp "  Press Enter once Backend A is stopped… "

  step "AFTER"
  sleep 1
  local after codes
  after="$(backends_seen 6)"
  codes="$(http_codes 6)"
  info "six requests served by: $after"
  info "HTTP status codes:      $codes"

  if [[ "$after" != *A* && "$after" == *B* ]]; then
    ok "all traffic shifted to Backend B"
  else
    err "expected B only, got '$after' — is Backend A really stopped?"
  fi
  printf '%s' "$codes" | grep -q 502 \
    && warn "some requests 502'd — check max_fails/proxy_next_upstream" \
    || ok "no 502s leaked to the client"

  step "LAYER AFFECTED"
  cat <<'LAYER'
  Application layer (OSI 7 / TCP-IP application).

  Everything below it was untouched, and you can show that:
    DNS  — dig still returns the edge IP
    TCP  — the handshake to the edge still completes
    TLS  — the certificate still validates
  Only the origin serving the response changed. This is precisely the
  distinction the spec asks you to make between a DNS failure (resolution
  stops) and an application failure (resolution works, the app is down).

LAYER

  read -rp "  Restart Backend A on Mac 3, then press Enter… "
  sleep 2
  local restored; restored="$(backends_seen 6)"
  info "six requests served by: $restored"
  [[ "$restored" == *A* && "$restored" == *B* ]] \
    && ok "RESTORED — round-robin resumed across both backends" \
    || warn "Backend A has not rejoined the pool yet; wait for fail_timeout (10s) and retry."

  {
    echo "=== D3 Failure demo — Option A: stop one backend ==="
    echo
    echo "BEFORE (6 requests): $before"
    echo "ACTION: stopped the Backend A process on Mac 3 ($BACKEND_A_IP:$BACKEND_A_PORT)"
    echo "AFTER  (6 requests): $after"
    echo "HTTP codes after:    $codes"
    echo "LAYER: application — DNS, TCP and TLS all unaffected"
    echo "RESTORED (6 requests): $restored"
  } > "$OUT/D3-failure-demo.txt"
  ok "Evidence -> evidence/D-cache-fail/D3-failure-demo.txt"
}

# ─────────────────────────────────────────────────────────────────────────
demo_B() {
  hdr "Option B — wrong DNS server on this client"
  cat <<'WHY'
  What this proves: name resolution and IP connectivity are independent.
  Point the resolver somewhere that has never heard of our private name and
  the lookup fails, while the machine is still perfectly able to reach the
  edge by address.

WHY

  step "BEFORE"
  local before; before="$(dig +short "$APP_DOMAIN" | head -1)"
  info "$APP_DOMAIN -> ${before:-<none>}"
  [[ "$before" == "$EDGE_IP" ]] || { err "DNS is not working correctly to begin with."; return 1; }
  ok "resolves to the edge"

  step "ACTION — switching this machine's resolver to 8.8.8.8"
  sudo networksetup -setdnsservers "$NET_SERVICE" 8.8.8.8
  sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder 2>/dev/null || true
  sleep 1

  step "AFTER"
  local after curlout pingout
  after="$(dig "$APP_DOMAIN" 2>&1 | grep -E 'status:|^;; SERVER' | tr '\n' ' ')"
  info "dig: $after"
  curlout="$(curl -s --max-time 5 "$APP_URL/api/status" 2>&1 || true)"
  info "curl by name: ${curlout:0:80}"
  pingout="$(ping -c2 -W1000 "$EDGE_IP" 2>&1 | awk -F', ' '/packet loss/{print $3}')"
  info "ping $EDGE_IP: $pingout"

  printf '%s' "$after" | grep -q NXDOMAIN && ok "NXDOMAIN — the private name does not exist publicly"
  printf '%s' "$pingout" | grep -q '^0.0%' \
    && ok "the edge is STILL reachable by IP — only the name lookup broke"

  step "LAYER AFFECTED"
  cat <<'LAYER'
  Application layer (DNS is an application-layer protocol running over
  UDP/53). The network layer is untouched: ICMP to the edge's IP still gets
  replies, and a curl to the raw IP would still reach nginx.

  This is the cleanest demonstration in the set that DNS is a *directory*,
  not a connection.

LAYER

  read -rp "  Press Enter to restore DNS… "
  "$REPO_ROOT/infra/client/reset-dns.sh"
  sleep 1
  local restored; restored="$(dig +short "$APP_DOMAIN" | head -1)"
  [[ "$restored" == "$EDGE_IP" ]] && ok "RESTORED — $APP_DOMAIN -> $restored" \
    || warn "Not resolving yet; run: make client-dns"

  {
    echo "=== D3 Failure demo — Option B: wrong DNS server on the client ==="
    echo
    echo "BEFORE: dig $APP_DOMAIN -> $before (via our DNS $DNS_IP)"
    echo "ACTION: networksetup -setdnsservers $NET_SERVICE 8.8.8.8"
    echo "AFTER:  $after"
    echo "        curl by name: ${curlout:0:120}"
    echo "        ping $EDGE_IP: $pingout  <- still reachable by IP"
    echo "LAYER:  application (DNS). Network layer unaffected."
    echo "RESTORED: dig $APP_DOMAIN -> $restored"
  } > "$OUT/D3-failure-demo.txt"
  ok "Evidence -> evidence/D-cache-fail/D3-failure-demo.txt"
}

# ─────────────────────────────────────────────────────────────────────────
demo_C() {
  hdr "Option C — wrong destination port"
  cat <<'WHY'
  What this proves: an IP address identifies a HOST; a port identifies a
  SERVICE on that host. Same reachable machine, no listener on the port,
  connection refused.

WHY

  step "BEFORE"
  local before; before="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$APP_URL/api/status")"
  info "$APP_URL/api/status -> HTTP $before"
  [[ "$before" == "200" ]] || { err "The service is not healthy to begin with."; return 1; }
  ok "service reachable on port $HTTPS_PORT"

  step "ACTION — same host and name, port 9999"
  local after
  after="$(curl -sv --max-time 5 "https://$APP_DOMAIN:9999/api/status" 2>&1 || true)"
  printf '%s\n' "$after" | grep -iE 'trying|connect to|refused|failed' | sed 's/^/    /'

  local pingout; pingout="$(ping -c2 -W1000 "$EDGE_IP" 2>&1 | awk -F', ' '/packet loss/{print $3}')"
  info "ping $EDGE_IP: $pingout"
  printf '%s' "$after" | grep -qi refused && ok "connection refused on :9999"
  printf '%s' "$pingout" | grep -q '^0.0%' && ok "the host itself is perfectly reachable"

  step "LAYER AFFECTED"
  cat <<'LAYER'
  Transport layer (TCP). The IP packet arrived at the correct host — that is
  the network layer doing its job. The host's TCP stack found no socket
  listening on port 9999 and replied with RST, which curl reports as
  "Connection refused".

  Nothing was ever sent at the TLS or HTTP layer: there was no connection to
  send it over. Note also that DNS succeeded — the name resolved fine; it is
  only the port that is wrong.

LAYER

  ok "Nothing to restore — this demo changes no state."
  {
    echo "=== D3 Failure demo — Option C: wrong destination port ==="
    echo
    echo "BEFORE: curl $APP_URL/api/status -> HTTP $before"
    echo "ACTION: curl https://$APP_DOMAIN:9999/api/status"
    echo "AFTER:"
    printf '%s\n' "$after" | grep -iE 'trying|connect to|refused|failed' | sed 's/^/  /'
    echo "        ping $EDGE_IP: $pingout  <- host reachable, port is not"
    echo "LAYER:  transport (TCP). Host reached; no listener on :9999 -> RST."
    echo "RESTORED: no state was changed."
  } > "$OUT/D3-failure-demo.txt"
  ok "Evidence -> evidence/D-cache-fail/D3-failure-demo.txt"
}

# ─────────────────────────────────────────────────────────────────────────
demo_D() {
  hdr "Option D — both backends stopped (502 Bad Gateway)"
  cat <<'WHY'
  What this proves: where the edge ends and the application begins. DNS
  resolves, TCP connects, TLS completes — and THEN the edge reports that it
  has no healthy origin. The 502 is generated by nginx, not by a backend.

WHY
  step "BEFORE"
  info "six requests served by: $(backends_seen 6)"
  warn "Stop BOTH backends (Ctrl-C on Mac 3 and Mac 4)."
  read -rp "  Press Enter once both are stopped… "

  step "AFTER"
  local v; v="$(curl -sv --max-time 8 "$APP_URL/api/status" 2>&1 || true)"
  printf '%s\n' "$v" | grep -iE 'SSL connection|SSL certificate verify|^< HTTP|502' | sed 's/^/    /'
  printf '%s' "$v" | grep -qi "SSL certificate verify ok" && ok "TLS still completes — the edge is healthy"
  printf '%s' "$v" | grep -q "502" && ok "502 Bad Gateway returned by nginx"
  info "edge-health: $(curl -s --max-time 5 "$APP_URL/edge-health" || echo '<none>')"

  step "LAYER AFFECTED"
  echo "  Application layer, upstream of the edge. Everything up to and"
  echo "  including TLS termination worked; only the origin pool is empty."
  echo
  read -rp "  Restart both backends, then press Enter… "
  sleep 2
  ok "RESTORED — served by: $(backends_seen 6)"
}

# ─────────────────────────────────────────────────────────────────────────
case "${1:-}" in
  A|a) demo_A ;;
  B|b) demo_B ;;
  C|c) demo_C ;;
  D|d) demo_D ;;
  '')
    hdr "Failure demonstrations — spec §6.3 / form D3"
    cat <<MENU

  Pick ONE for the form and the video. Option A is recommended: it is the
  most visual, takes under a minute, and recovers cleanly on camera.

    ${C_BLD}A${C_OFF}  Stop one backend          application layer   ${C_GRN}recommended for the video${C_OFF}
    ${C_BLD}B${C_OFF}  Wrong DNS on the client   application (DNS)
    ${C_BLD}C${C_OFF}  Wrong destination port    transport (TCP)     ${C_DIM}no state changed${C_OFF}
    ${C_BLD}D${C_OFF}  Both backends stopped     502 from the edge

MENU
    read -rp "  Choice [A/B/C/D]: " c
    case "$c" in A|a) demo_A ;; B|b) demo_B ;; C|c) demo_C ;; D|d) demo_D ;; *) die "Nothing selected." ;; esac
    ;;
  *) die "Unknown option '$1'. Use A, B, C or D." ;;
esac
