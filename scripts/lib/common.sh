#!/usr/bin/env bash
# Shared helpers for every script in this repo.
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# Loads .env, exposes colour logging, assertions and a pass/fail tally.

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
# REPO_ROOT resolves correctly no matter which directory the caller ran from.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
export REPO_ROOT

# ── Colour (disabled when not a TTY, so redirected evidence files stay clean) ─
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_BLD=''; C_OFF=''
fi

log()   { printf '%s\n' "$*"; }
info()  { printf '%s→%s %s\n'  "$C_BLU" "$C_OFF" "$*"; }
ok()    { printf '%s✓%s %s\n'  "$C_GRN" "$C_OFF" "$*"; }
warn()  { printf '%s!%s %s\n'  "$C_YEL" "$C_OFF" "$*" >&2; }
err()   { printf '%s✗%s %s\n'  "$C_RED" "$C_OFF" "$*" >&2; }
die()   { err "$*"; exit 1; }
hdr()   { printf '\n%s%s%s\n%s\n' "$C_BLD" "$*" "$C_OFF" "$(printf '─%.0s' $(seq 1 ${#1}))"; }
step()  { printf '\n%s%s%s\n' "$C_BLD" "$*" "$C_OFF"; }

# ── .env loading ─────────────────────────────────────────────────────────────
load_env() {
  local envfile="$REPO_ROOT/.env"
  if [[ ! -f "$envfile" ]]; then
    err "No .env found at $envfile"
    err "Run:  cp .env.example .env  && edit it with your real IPs"
    exit 1
  fi
  # shellcheck disable=SC1090
  set -a; source "$envfile"; set +a

  local missing=()
  for v in TEAM APP_DOMAIN API_DOMAIN DNS_IP EDGE_IP BACKEND_A_IP BACKEND_B_IP \
           IFACE NET_SERVICE HTTP_PORT HTTPS_PORT BACKEND_A_PORT BACKEND_B_PORT \
           DNS_TTL UPSTREAM_DNS CACHE_MAX_AGE; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  (( ${#missing[@]} == 0 )) || die ".env is missing: ${missing[*]}"

  # Derived. Port 443 is implicit in a URL; anything else must be explicit.
  if [[ "$HTTPS_PORT" == "443" ]]; then
    export APP_URL="https://$APP_DOMAIN"
    export API_URL="https://$API_DOMAIN"
    export PORT_SUFFIX=""
  else
    export APP_URL="https://$APP_DOMAIN:$HTTPS_PORT"
    export API_URL="https://$API_DOMAIN:$HTTPS_PORT"
    export PORT_SUFFIX=":$HTTPS_PORT"
  fi
  export CERT_DIR="$REPO_ROOT/infra/mac2-edge/certs"
  export BREW_PREFIX="${BREW_PREFIX:-$(brew --prefix 2>/dev/null || echo /opt/homebrew)}"
}

# ── Assertions with a running tally (used by verify-all.sh) ──────────────────
PASS_COUNT=0
FAIL_COUNT=0
FAILED_CHECKS=()

check() {
  # check "<description>" <command...>   — runs quietly, records pass/fail
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ok "$desc"; PASS_COUNT=$((PASS_COUNT + 1)); return 0
  else
    err "$desc"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_CHECKS+=("$desc"); return 1
  fi
}

check_contains() {
  # check_contains "<description>" "<haystack>" "<needle>"
  local desc="$1" hay="$2" needle="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    ok "$desc"; PASS_COUNT=$((PASS_COUNT + 1)); return 0
  else
    err "$desc  ${C_DIM}(expected to find: $needle)${C_OFF}"
    FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_CHECKS+=("$desc"); return 1
  fi
}

check_icontains() {
  # Case-INSENSITIVE contains. Required for HTTP header checks: over HTTP/2
  # all header names are lowercase by protocol ("etag:", not "ETag:"), so a
  # case-sensitive match silently fails the moment http2 is enabled.
  local desc="$1" hay="$2" needle="$3"
  if [[ "$(printf '%s' "$hay" | tr 'A-Z' 'a-z')" == *"$(printf '%s' "$needle" | tr 'A-Z' 'a-z')"* ]]; then
    ok "$desc"; PASS_COUNT=$((PASS_COUNT + 1)); return 0
  else
    err "$desc  ${C_DIM}(expected to find: $needle)${C_OFF}"
    FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_CHECKS+=("$desc"); return 1
  fi
}

check_not_contains() {
  local desc="$1" hay="$2" needle="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    ok "$desc"; PASS_COUNT=$((PASS_COUNT + 1)); return 0
  else
    err "$desc  ${C_DIM}(should NOT contain: $needle)${C_OFF}"
    FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_CHECKS+=("$desc"); return 1
  fi
}

summary() {
  local total=$((PASS_COUNT + FAIL_COUNT))
  printf '\n%s%s%s\n' "$C_BLD" "──────── $PASS_COUNT/$total checks passed ────────" "$C_OFF"
  if (( FAIL_COUNT > 0 )); then
    err "Failed:"
    for f in "${FAILED_CHECKS[@]}"; do printf '    • %s\n' "$f" >&2; done
    printf '\n  See %sdocs/troubleshooting.md%s for symptom → layer → fix.\n\n' "$C_BLD" "$C_OFF" >&2
    return 1
  fi
  ok "All Phase 1 acceptance criteria met."
  return 0
}

# ── Machine-role detection ───────────────────────────────────────────────────
my_ip() { ipconfig getifaddr "$IFACE" 2>/dev/null || echo ""; }

my_role() {
  local ip; ip="$(my_ip)"
  case "$ip" in
    "$DNS_IP")       echo "mac1-dns" ;;
    "$EDGE_IP")      echo "mac2-edge" ;;
    "$BACKEND_A_IP") echo "mac3-backend-a" ;;
    "$BACKEND_B_IP") echo "mac4-backend-b" ;;
    *)               echo "unknown" ;;
  esac
}

require_role() {
  # require_role mac2-edge — refuse to run edge setup on the DNS box
  local want="$1" have; have="$(my_role)"
  if [[ "$have" != "$want" ]]; then
    warn "This script is meant for ${C_BLD}$want${C_OFF} but this machine looks like ${C_BLD}$have${C_OFF} ($(my_ip))."
    read -rp "Continue anyway? [y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] || exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found. Install it:  brew install ${2:-$1}"
}

confirm() {
  read -rp "$(printf '%s?%s %s [y/N] ' "$C_YEL" "$C_OFF" "$1")" a
  [[ "$a" =~ ^[Yy]$ ]]
}
