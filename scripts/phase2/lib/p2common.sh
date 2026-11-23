#!/usr/bin/env bash
# Phase 2 shared helpers.
#   source "$(dirname "$0")/lib/p2common.sh"       (from scripts/phase2/*.sh)
#
# Layout — every Phase 2 file sits in a phase2/ subfolder of its Phase 1 home:
#   scripts/phase2/            runnable scripts        (this lib: scripts/phase2/lib/)
#   scripts/phase2/phase2.mk   make targets, included by the root Makefile
#   infra/phase2/              pf template, .env.phase2, certs/ and build/ (gitignored)
#   docs/phase2/               documentation
#   evidence/phase2/           evidence written by the demo/verify scripts
#
# This BUILDS ON the Phase 1 library (scripts/lib/common.sh): same .env, same
# logging, same check/summary assertions, same role detection. Nothing in
# Phase 1 is modified — Phase 2 only adds.
#
# Key idea: Phase 2 does not fork the Phase 1 configs. It renders the SAME
# Phase 1 templates (dnsmasq.conf.template, nginx.conf.template,
# site.conf.template) with a few values overridden:
#   backup DNS     = Phase 1 dnsmasq template, DNS_TTL=30, on another Mac
#   TTL / cutover  = Phase 1 dnsmasq template, DNS_TTL=30, EDGE_IP=<target>
#   standby edge   = Phase 1 nginx templates,  EDGE_IP=<standby Mac>
# One source of truth: fix a template once and every profile inherits it.

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"   # scripts/lib/common.sh

# ── Paths ────────────────────────────────────────────────────────────────────
P2_SCRIPTS="$REPO_ROOT/scripts/phase2"
P2_INFRA="$REPO_ROOT/infra/phase2"
P2_BUILD="$P2_INFRA/build"                 # rendered Phase 2 configs (gitignored)
P2_STATE="$P2_BUILD/state"                 # per-machine state: backups, pf token, edge target
P2_CERT_DIR="$P2_INFRA/certs"              # copy of Mac 2's cert/key for the standby edge (gitignored)
P2_EVIDENCE="$REPO_ROOT/evidence/phase2"
P2_DOCS="$REPO_ROOT/docs/phase2"
export P2_SCRIPTS P2_INFRA P2_BUILD P2_STATE P2_CERT_DIR P2_EVIDENCE P2_DOCS

P1_DNS_TPL="$REPO_ROOT/infra/mac1-dns/dnsmasq.conf.template"
P1_NGX_TPL="$REPO_ROOT/infra/mac2-edge/nginx/nginx.conf.template"
P1_SITE_TPL="$REPO_ROOT/infra/mac2-edge/nginx/conf.d/site.conf.template"
# NOTE the .tpl extension, not .template: Phase 1's render-configs.sh renders
# every *.template under infra/ and would abort on this file's {{BACKEND_PORT}}
# — which would break `make render`, `make dns` and `make edge`.
P2_PF_TPL="$P2_INFRA/pf/backend-isolation.pf.tpl"

# pf anchor. macOS's stock /etc/pf.conf already contains `anchor "com.apple/*"`,
# so rules loaded into a child of com.apple are evaluated WITHOUT editing any
# system file. Rollback is then a single flush of this anchor.
PF_ANCHOR="com.apple/250.ParadiseIsolation"

# ── Environment ──────────────────────────────────────────────────────────────
load_p2_env() {
  load_env   # Phase 1: .env, the 16 required variables, APP_URL, CERT_DIR…

  # Optional overrides, kept separate so Phase 1's .env stays untouched.
  if [[ -f "$P2_INFRA/.env.phase2" ]]; then
    # shellcheck disable=SC1091
    set -a; source "$P2_INFRA/.env.phase2"; set +a
  fi

  # Phase 2 variables. Defaults follow the agreed placement:
  #   backup DNS  -> Mac 4 (Backend B's machine)
  #   standby edge-> Mac 4 (Backend B's machine)
  # Both extras share Mac 4, so Mac 3 stays a plain backend + client — the
  # cleanest vantage point for the Ext A/B/E client demos.
  export BACKUP_DNS_IP="${BACKUP_DNS_IP:-$BACKEND_B_IP}"
  export STANDBY_EDGE_IP="${STANDBY_EDGE_IP:-$BACKEND_B_IP}"
  export P2_DNS_TTL="${P2_DNS_TTL:-30}"
  export HEALTH_INTERVAL="${HEALTH_INTERVAL:-2}"

  [[ "$BACKUP_DNS_IP"   != "$DNS_IP"  ]] || die "BACKUP_DNS_IP must not be Mac 1 (spec Ext A: 'another Mac (not Mac 1)')."
  [[ "$STANDBY_EDGE_IP" != "$EDGE_IP" ]] || die "STANDBY_EDGE_IP must not be Mac 2 — a standby on the same box is not a standby."

  mkdir -p "$P2_BUILD" "$P2_STATE" "$P2_EVIDENCE"
}

# ── Roles (Phase 2 adds two roles on top of Phase 1's four) ─────────────────
is_primary_dns()  { [[ "$(my_ip)" == "$DNS_IP" ]]; }
is_backup_dns()   { [[ "$(my_ip)" == "$BACKUP_DNS_IP" ]]; }
is_edge()         { [[ "$(my_ip)" == "$EDGE_IP" ]]; }
is_standby_edge() { [[ "$(my_ip)" == "$STANDBY_EDGE_IP" ]]; }

p2_require_ip() {
  # p2_require_ip <ip> "<role description>"   — like Phase 1 require_role, by IP
  local want="$1" label="$2" have; have="$(my_ip)"
  if [[ "$have" != "$want" ]]; then
    warn "This step belongs on the ${C_BLD}$label${C_OFF} ($want), but this machine is ${have:-<no IP on $IFACE>} ($(my_role))."
    read -rp "Continue anyway? [y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] || exit 1
  fi
}

# ── Edge target: which edge the DNS records currently point at ──────────────
# Stored per DNS machine, so a re-render never silently undoes a cutover.
edge_target_ip() {
  local f="$P2_STATE/edge-target"
  if [[ -s "$f" ]]; then cat "$f"; else echo "$EDGE_IP"; fi
}
set_edge_target() { printf '%s\n' "$1" > "$P2_STATE/edge-target"; }

edge_label() {
  case "$1" in
    "$EDGE_IP")         echo "primary edge (Mac 2)" ;;
    "$STANDBY_EDGE_IP") echo "standby edge" ;;
    *)                  echo "UNKNOWN host" ;;
  esac
}

# ── Rendering: Phase 1 templates + overrides ────────────────────────────────
P2_VARS=(TEAM APP_DOMAIN API_DOMAIN DNS_IP EDGE_IP BACKEND_A_IP BACKEND_B_IP
         IFACE NET_SERVICE HTTP_PORT HTTPS_PORT BACKEND_A_PORT BACKEND_B_PORT
         DNS_TTL UPSTREAM_DNS CACHE_MAX_AGE CERT_DIR BREW_PREFIX
         BACKUP_DNS_IP STANDBY_EDGE_IP P2_DNS_TTL)

p2_render() {
  # p2_render <template> <output> "<banner>" [VAR=value ...]
  # Same engine as scripts/render-configs.sh (BSD sed, | delimiter, fail on
  # leftover {{…}}), but overrides apply only inside a subshell so they can
  # never leak into the caller's environment.
  local tpl="$1" out="$2" banner="$3"; shift 3
  [[ -f "$tpl" ]] || die "Template not found: $tpl"
  mkdir -p "$(dirname "$out")"
  local tmp; tmp="$(mktemp)"
  {
    printf '# ── PHASE 2 PROFILE: %s\n' "$banner"
    printf '# ── Rendered from %s (Phase 1 template, unmodified)\n' "${tpl#"$REPO_ROOT"/}"
    if (( $# > 0 )); then printf '# ── Overrides: %s\n' "$*"; fi
    printf '# ── Regenerate with: make p2-render     GENERATED — do not edit.\n\n'
    cat "$tpl"
  } > "$tmp"

  (
    keys=("${P2_VARS[@]}")
    for kv in "$@"; do
      export "${kv%%=*}=${kv#*=}"
      keys+=("${kv%%=*}")
    done
    for v in "${keys[@]}"; do
      LC_ALL=C sed -i '' "s|{{$v}}|${!v}|g" "$tmp"
    done
  )

  if grep -q '{{[A-Z_]*}}' "$tmp"; then
    err "Unsubstituted placeholders in $out:"
    grep -o '{{[A-Z_]*}}' "$tmp" | sort -u | sed 's/^/      /' >&2
    rm -f "$tmp"; exit 1
  fi
  mv "$tmp" "$out"; chmod 644 "$out"
  ok "${out#"$REPO_ROOT"/}"
}

# Fixed output locations, so every script agrees on where things live.
P2_PRIMARY_DNS_CONF="$P2_BUILD/primary-dns/dnsmasq.conf"
P2_BACKUP_DNS_CONF="$P2_BUILD/backup-dns/dnsmasq.conf"
P2_STANDBY_NGX_CONF="$P2_BUILD/standby-edge/nginx.conf"
P2_STANDBY_SITE_CONF="$P2_BUILD/standby-edge/conf.d/site.conf"
P2_PF_A_CONF="$P2_BUILD/pf/backend-a.pf.conf"
P2_PF_B_CONF="$P2_BUILD/pf/backend-b.pf.conf"

render_dns_profile() {
  # render_dns_profile <primary|backup> <target-edge-ip>
  local which="$1" target="$2" out ip label
  if [[ "$which" == primary ]]; then
    out="$P2_PRIMARY_DNS_CONF"; ip="$DNS_IP";        label="primary DNS · Mac 1 · $DNS_IP"
  else
    out="$P2_BACKUP_DNS_CONF";  ip="$BACKUP_DNS_IP"; label="BACKUP DNS · $BACKUP_DNS_IP"
  fi
  p2_render "$P1_DNS_TPL" "$out" "$label · TTL ${P2_DNS_TTL}s · records -> $target ($(edge_label "$target"))" \
    DNS_IP="$ip" EDGE_IP="$target" DNS_TTL="$P2_DNS_TTL"
}

render_standby_edge() {
  p2_render "$P1_NGX_TPL"  "$P2_STANDBY_NGX_CONF"  "STANDBY EDGE · $STANDBY_EDGE_IP" \
    EDGE_IP="$STANDBY_EDGE_IP" CERT_DIR="$P2_CERT_DIR"
  p2_render "$P1_SITE_TPL" "$P2_STANDBY_SITE_CONF" "STANDBY EDGE · $STANDBY_EDGE_IP" \
    EDGE_IP="$STANDBY_EDGE_IP" CERT_DIR="$P2_CERT_DIR"
}

render_pf() {
  # Allow-list = both edges. The standby edge must also reach the backends,
  # otherwise Extension E's cutover would land on an edge that 502s.
  p2_render "$P2_PF_TPL" "$P2_PF_A_CONF" "pf isolation · Backend A · :$BACKEND_A_PORT" \
    BACKEND_PORT="$BACKEND_A_PORT" BACKEND_LABEL="Backend A"
  p2_render "$P2_PF_TPL" "$P2_PF_B_CONF" "pf isolation · Backend B · :$BACKEND_B_PORT" \
    BACKEND_PORT="$BACKEND_B_PORT" BACKEND_LABEL="Backend B"
}

# ── dnsmasq service helpers (same strategy as infra/mac1-dns/install.sh) ────
DNSMASQ_DST() { echo "$BREW_PREFIX/etc/dnsmasq.conf"; }

dnsmasq_install_conf() {
  # dnsmasq_install_conf <rendered conf>  — validate, back up once, install
  local src="$1" dst; dst="$(DNSMASQ_DST)"
  need_cmd dnsmasq
  info "Validating $(basename "$(dirname "$src")")/$(basename "$src")…"
  if ! sudo dnsmasq --test --conf-file="$src" 2>&1 | grep -q "syntax check OK"; then
    sudo dnsmasq --test --conf-file="$src" 2>&1 | sed 's/^/      /' >&2
    die "dnsmasq rejected the config — nothing was changed."
  fi
  ok "Config syntax OK"
  if [[ -f "$dst" && ! -f "$dst.pre-phase2" ]]; then
    sudo cp "$dst" "$dst.pre-phase2"
    ok "Rollback copy saved -> $dst.pre-phase2"
  fi
  sudo cp "$src" "$dst"
  sudo mkdir -p "$BREW_PREFIX/var/log"
  sudo touch "$BREW_PREFIX/var/log/dnsmasq.log"; sudo chmod 644 "$BREW_PREFIX/var/log/dnsmasq.log"
  ok "Installed $dst"
}

dnsmasq_restart() {
  # address= records are read only at startup — SIGHUP re-reads hosts files,
  # not the config — so a record change needs a real restart.
  local dst; dst="$(DNSMASQ_DST)"
  info "Restarting dnsmasq…"
  if ! sudo brew services restart dnsmasq >/dev/null 2>&1; then
    warn "launchd refused — clearing a stale registration and retrying."
    sudo launchctl bootout system/sh.brew.dnsmasq 2>/dev/null || true
    sleep 1
    if ! sudo brew services start dnsmasq >/dev/null 2>&1; then
      warn "Running dnsmasq directly (does not survive reboot)."
      sudo pkill -x dnsmasq 2>/dev/null || true; sleep 1
      sudo dnsmasq --conf-file="$dst"
    fi
  fi
  sleep 2
  sudo lsof -nP -iUDP:53 2>/dev/null | grep -q dnsmasq || die "dnsmasq is not listening on UDP/53 — see $BREW_PREFIX/var/log/dnsmasq.log"
  ok "dnsmasq listening on UDP/53"
}

dnsmasq_stop() {
  sudo brew services stop dnsmasq >/dev/null 2>&1 || true
  sudo pkill -x dnsmasq 2>/dev/null || true
  sleep 1
}

dnsmasq_running() { pgrep -x dnsmasq >/dev/null 2>&1; }

port53_free_or_dnsmasq() {
  local c; c="$(sudo lsof -nP -iUDP:53 -iTCP:53 2>/dev/null | awk 'NR>1 && $1 != "dnsmasq"')"
  if [[ -n "$c" ]]; then
    err "Port 53 is held by another process:"; printf '%s\n' "$c" | sed 's/^/      /' >&2
    err "Only one process may own :53. Pick a different BACKUP_DNS_IP in infra/phase2/.env.phase2."
    return 1
  fi
}

# ── DNS query helpers ───────────────────────────────────────────────────────
# Every helper ends in `|| true`: "no answer" is a normal result to report,
# and under set -e + pipefail an empty grep would otherwise kill the caller.
dig_a()   { dig +short +time=2 +tries=1 "@$1" "$2" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true; }
dig_ttl() { dig +noall +answer +time=2 +tries=1 "@$1" "$2" A 2>/dev/null | awk '$4=="A"{print $2; exit}' || true; }
os_cache_ip() {
  # What the OS resolver (mDNSResponder, which honours TTL) hands applications.
  # dig bypasses this cache entirely — that contrast IS the Extension B demo.
  dscacheutil -q host -a name "$1" 2>/dev/null | awk '/^ip_address:/{print $2; exit}' || true
}
flush_client_dns() {
  sudo dscacheutil -flushcache
  sudo killall -HUP mDNSResponder 2>/dev/null || true
}

# ── HTTP helper: one request, parsed ─────────────────────────────────────────
# Sets REQ_CODE REQ_BACKEND REQ_EDGE REQ_REMOTE REQ_UPSTREAM for the caller.
one_request() {
  local url="${1:-$APP_URL/api/status}" raw
  raw="$(curl -s -D - -o /dev/null --connect-timeout 3 --max-time 5 \
          -w 'REMOTE_IP: %{remote_ip}\n' "$url" 2>/dev/null || true)"
  REQ_CODE="$(printf '%s' "$raw" | awk 'NR==1{print $2}')"
  REQ_BACKEND="$(printf '%s' "$raw" | awk -F': ' 'tolower($1)=="x-backend"{gsub(/\r/,"");print $2;exit}')"
  REQ_EDGE="$(printf '%s' "$raw" | awk -F': ' 'tolower($1)=="x-edge"{gsub(/\r/,"");print $2;exit}')"
  REQ_REMOTE="$(printf '%s' "$raw" | awk -F': ' '$1=="REMOTE_IP"{print $2;exit}')"
  REQ_UPSTREAM="$(printf '%s' "$raw" | awk -F': ' 'tolower($1)=="x-upstream-addr"{gsub(/\r/,"");print $2;exit}')"
  REQ_CODE="${REQ_CODE:-000}"
}

# ── Evidence capture: show on screen AND append to a clean (colourless) file ─
EV_FILE=""
ev_open() {
  # ev_open <relative-path-under-evidence/phase2> "<title>"
  EV_FILE="$P2_EVIDENCE/$1"; mkdir -p "$(dirname "$EV_FILE")"
  {
    printf '# %s\n' "$2"
    printf '# machine: %s (%s)   date: %s\n' "$(my_ip)" "$(my_role)" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '# generated by: scripts/phase2/%s\n\n' "$(basename "$0")"
  } > "$EV_FILE"
}
_ev_strip() { sed -E $'s/\x1b\\[[0-9;]*m//g'; }
ev_note()  { printf '%s\n' "$*"; [[ -n "$EV_FILE" ]] && printf '%s\n' "$*" | _ev_strip >> "$EV_FILE"; return 0; }
ev_run() {
  # ev_run "<shell command>"  — echo it, run it, tee output; never aborts
  printf '\n%s$ %s%s\n' "$C_DIM" "$1" "$C_OFF"
  [[ -n "$EV_FILE" ]] && printf '\n$ %s\n' "$1" >> "$EV_FILE"
  local out; out="$( (eval "$1") 2>&1 || true)"
  printf '%s\n' "$out"
  [[ -n "$EV_FILE" ]] && printf '%s\n' "$out" | _ev_strip >> "$EV_FILE"
  return 0
}
ev_pause() {
  # ev_pause "<instruction for a human on another Mac>"
  printf '\n%s▶ %s%s\n' "$C_YEL$C_BLD" "$*" "$C_OFF"
  [[ -n "$EV_FILE" ]] && printf '\n>>> ACTION: %s\n' "$*" >> "$EV_FILE"
  read -rp "  Press Enter when done… " _
}
ev_close() {
  [[ -n "$EV_FILE" ]] && info "Evidence written -> ${EV_FILE#"$REPO_ROOT"/}"
  return 0
}

# ── Phase 2 summary (Phase 1's summary() says "All Phase 1 criteria met") ───
p2_summary() {
  local label="${1:-Phase 2 checks}" total=$((PASS_COUNT + FAIL_COUNT))
  printf '\n%s%s%s\n' "$C_BLD" "──────── $PASS_COUNT/$total checks passed ────────" "$C_OFF"
  if (( FAIL_COUNT > 0 )); then
    err "Failed:"
    for f in "${FAILED_CHECKS[@]}"; do printf '    • %s\n' "$f" >&2; done
    printf '\n  Diagnose layer by layer: %smake p2-diagnose%s\n\n' "$C_BLD" "$C_OFF" >&2
    return 1
  fi
  ok "$label: all passed."
}
