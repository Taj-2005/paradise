#!/usr/bin/env bash
# [Mac 3 and Mac 4 · backends]  Extension C — only the edges may reach :3001/:3002.
#
# 1. Snapshot the current pf state (rollback copy, as the spec requires)
# 2. Parse-check the rules (pfctl -n) before touching anything live
# 3. Load them into our own anchor under com.apple/* — /etc/pf.conf untouched
# 4. Enable pf with a reference token, so rollback releases exactly our hold
#
#   ./install-isolation.sh          # auto-detects A or B from this Mac's IP
#   ./install-isolation.sh A|B      # force

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

which="${1:-}"
if [[ -z "$which" ]]; then
  case "$(my_ip)" in
    "$BACKEND_A_IP") which=A ;;
    "$BACKEND_B_IP") which=B ;;
    *) die "This Mac ($(my_ip)) is neither backend. Pass A or B explicitly." ;;
  esac
fi
case "$which" in
  A) PORT="$BACKEND_A_PORT"; CONF="$P2_PF_A_CONF" ;;
  B) PORT="$BACKEND_B_PORT"; CONF="$P2_PF_B_CONF" ;;
  *) die "Usage: $(basename "$0") [A|B]" ;;
esac

hdr "Extension C — isolate Backend $which (:$PORT) with pf"
render_pf >/dev/null
info "Rules: ${CONF#"$REPO_ROOT"/}"
sed -n '/^[a-z]/p' "$CONF" | sed 's/^/      /'

# ── 1. Rollback copy ─────────────────────────────────────────────────────────
SNAP="$P2_STATE/pf-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SNAP"
sudo pfctl -s info 2>/dev/null | head -1 > "$SNAP/status.txt" || true
sudo pfctl -sr     2>/dev/null           > "$SNAP/main-rules.txt" || true
sudo pfctl -a "$PF_ANCHOR" -sr 2>/dev/null > "$SNAP/anchor-rules.txt" || true
cp "$CONF" "$SNAP/applied-rules.conf"
ln -sfn "$SNAP" "$P2_STATE/pf-backup-latest"
ok "Rollback snapshot -> ${SNAP#"$REPO_ROOT"/}  (pf was: $(cat "$SNAP/status.txt"))"

# ── 2. Validate ─────────────────────────────────────────────────────────────
if ! sudo pfctl -a "$PF_ANCHOR" -nf "$CONF" 2>"$SNAP/parse.err"; then
  sed 's/^/      /' "$SNAP/parse.err" >&2
  die "pfctl rejected the rules — nothing was loaded."
fi
ok "Rules parse (pfctl -n)"

# ── 3. Load into our anchor ─────────────────────────────────────────────────
sudo pfctl -a "$PF_ANCHOR" -f "$CONF" 2>/dev/null
ok "Loaded into anchor $PF_ANCHOR"

# ── 4. Enable pf, keeping the reference token ───────────────────────────────
# `pfctl -E` increments pf's enable reference count and prints a token.
# `pfctl -X <token>` later releases ONLY our reference — if pf was already on
# for something else (Internet Sharing, a VPN), it stays on.
tok="$(sudo pfctl -E 2>&1 | awk '/Token/{print $NF}' || true)"
if [[ -n "$tok" ]]; then
  printf '%s\n' "$tok" >> "$P2_STATE/pf-tokens"
  ok "pf enabled (token $tok saved for rollback)"
fi

step "Active rules in our anchor"
sudo pfctl -a "$PF_ANCHOR" -sr 2>/dev/null | sed 's/^/    /'

step "Local sanity: this Mac can still reach its own backend over loopback"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT/healthz" || echo 000)"
[[ "$code" == 200 ]] && ok "127.0.0.1:$PORT/healthz -> 200" \
  || warn "127.0.0.1:$PORT/healthz -> $code (is the backend running? make backend-$(tr 'A-Z' 'a-z' <<<"$which"))"

cat <<NEXT

  ${C_BLD}Isolation active on Backend $which.${C_OFF}
  Prove it:
    on Mac 2 (edge)        make p2-isolation-test     # expect OPEN
    on Mac 1 (client)      make p2-isolation-test     # expect FILTERED (timeout)
  Roll back (restores the snapshot state):
    make p2-rollback WHAT=isolation

NEXT
