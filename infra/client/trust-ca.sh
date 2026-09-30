#!/usr/bin/env bash
# Any Mac — install the team's local root CA into the System keychain.
#
# THIS IS THE SCRIPT THAT KEEPS YOU OFF `-k`.
#
# Spec Task E: "Add your local CA certificate to the trust store of every
# client Mac so the browser or curl does not warn about an untrusted
# certificate. The final demonstration must not rely on bypassing certificate
# validation (no -k flag in curl for the demo)."
#
# Using -k in the evidence scores ZERO for the HTTPS section. Run this on all
# four Macs and you will never need it.

source "$(dirname "$0")/../../scripts/lib/common.sh"
load_env

hdr "Trust the $TEAM local root CA"

# Accept the CA from the repo, the home directory (after scp), or mkcert's
# own store — whichever is present.
CA=""
for candidate in \
  "$CERT_DIR/rootCA.pem" \
  "$HOME/rootCA.pem" \
  "$(mkcert -CAROOT 2>/dev/null)/rootCA.pem"
do
  [[ -f "$candidate" ]] && { CA="$candidate"; break; }
done

if [[ -z "$CA" ]]; then
  err "No root CA found. Looked in:"
  err "    $CERT_DIR/rootCA.pem"
  err "    \$HOME/rootCA.pem"
  err "    \$(mkcert -CAROOT)/rootCA.pem"
  echo
  err "Copy it from Mac 2 first:"
  err "    scp $EDGE_IP:~/cn-phase1-paradise/infra/mac2-edge/certs/rootCA.pem ~/"
  exit 1
fi

info "Using $CA"
openssl x509 -in "$CA" -noout -subject -dates | sed 's/^/      /'

# Already trusted? `verify` against the system store tells us definitively.
if security verify-cert -c "$CA" >/dev/null 2>&1; then
  ok "This CA is already trusted by the System keychain."
else
  info "Adding to the System keychain (requires your password)…"
  # -d = system domain, -r trustRoot = trust it as a root CA for SSL.
  sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain "$CA"
  ok "Added."
fi

# Firefox and some tools use their own NSS store rather than the keychain.
if command -v mkcert >/dev/null 2>&1; then
  mkcert -install >/dev/null 2>&1 && ok "mkcert store also up to date" || true
fi

step "Proving it — curl WITHOUT -k"
# --resolve stands in for DNS if this machine's resolver is not pointed at
# Mac 1 yet, so trust can be verified independently of the DNS layer.
OUT="$(curl -sv --max-time 5 \
        --resolve "$APP_DOMAIN:$HTTPS_PORT:$EDGE_IP" \
        "https://$APP_DOMAIN:$HTTPS_PORT/api/status" 2>&1 || true)"

if printf '%s' "$OUT" | grep -qi "SSL certificate verify ok"; then
  ok "Certificate verified with no -k flag. You are ready for evaluation."
  printf '%s\n' "$OUT" | grep -iE 'SSL connection using|subject:|issuer:|^< HTTP' | sed 's/^/      /'
elif printf '%s' "$OUT" | grep -qi "Connection refused\|Could not resolve\|Failed to connect"; then
  warn "Trust is installed, but the edge is not reachable from here yet."
  warn "Start nginx on Mac 2, then re-run this to confirm."
else
  err "Certificate still not trusted:"
  printf '%s\n' "$OUT" | grep -iE 'SSL|certificate|verify' | sed 's/^/      /' >&2
  err "Is this the same CA that signed the cert nginx is serving?"
  err "Regenerating the cert on Mac 2 makes a NEW CA — redistribute it."
  exit 1
fi

cat <<NEXT

  To remove this trust later:
      sudo security delete-certificate -c "$(openssl x509 -in "$CA" -noout -subject | sed 's/.*CN *= *//')" \\
        /Library/Keychains/System.keychain

NEXT
