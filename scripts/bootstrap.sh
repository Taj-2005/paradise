#!/usr/bin/env bash
# First-run setup for whichever machine you are on.
# Detects the role from this machine's IP and tells you exactly what to do.
#
#   ./scripts/bootstrap.sh

source "$(dirname "$0")/lib/common.sh"
load_env

hdr "Bootstrap — $(hostname -s)"

MY_IP="$(my_ip)"
ROLE="$(my_role)"

printf '  IP    %s (%s)\n' "${MY_IP:-<none>}" "$IFACE"
printf '  Role  %s\n\n' "$ROLE"

if [[ "$ROLE" == "unknown" ]]; then
  err "This machine's IP ($MY_IP) is not listed in .env."
  echo
  echo "  Edit .env so one of these matches:"
  printf '      DNS_IP=%s\n      EDGE_IP=%s\n      BACKEND_A_IP=%s\n      BACKEND_B_IP=%s\n' \
    "$DNS_IP" "$EDGE_IP" "$BACKEND_A_IP" "$BACKEND_B_IP"
  echo
  echo "  Then:  ./scripts/render-configs.sh && ./scripts/bootstrap.sh"
  exit 1
fi

# ── Common prerequisites ────────────────────────────────────────────────────
step "Prerequisites"
need_cmd brew
for c in curl dig nc; do command -v "$c" >/dev/null && ok "$c" || err "$c missing"; done

case "$ROLE" in
  mac1-dns)       PKGS="dnsmasq" ;;
  mac2-edge)      PKGS="nginx mkcert nss" ;;
  mac3-backend-a|mac4-backend-b) PKGS="node" ;;
esac

for p in $PKGS; do
  if brew list --formula "$p" >/dev/null 2>&1; then ok "$p installed"
  else info "installing $p…"; brew install "$p"; fi
done

# ── Role-specific next steps ────────────────────────────────────────────────
step "Next steps for this machine"
case "$ROLE" in
  mac1-dns) cat <<'S'
    1.  make dns              install + start dnsmasq
    2.  make client-dns       point this Mac at itself as resolver
    3.  make client-trust     after Mac 2 has generated the CA
S
  ;;
  mac2-edge) cat <<'S'
    1.  make edge             generate certs, install nginx config, start
    2.  Distribute the CA to the other three Macs:
          scp infra/mac2-edge/certs/rootCA.pem <user>@<each-mac>:~/
    3.  make client-dns
    4.  make client-trust
S
  ;;
  mac3-backend-a) cat <<'S'
    1.  make client-dns       point this Mac at Mac 1
    2.  make client-trust     after copying rootCA.pem from Mac 2
    3.  make backend-a        start Backend A (leave it in the foreground)
S
  ;;
  mac4-backend-b) cat <<'S'
    1.  make client-dns
    2.  make client-trust
    3.  make backend-b        start Backend B (leave it in the foreground)
S
  ;;
esac

cat <<NEXT

  Once all four machines are up, from a CLIENT machine (1, 3 or 4):

      make preflight        ping matrix + port reachability
      make verify           the full Phase 1 acceptance test
      make evidence         write the form answers into evidence/

NEXT
