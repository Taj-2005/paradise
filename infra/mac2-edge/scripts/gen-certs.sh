#!/usr/bin/env bash
# Mac 2 — generate the TLS certificate for the edge (spec Task E).
#
# Two paths, in order of preference:
#
#   mkcert   Creates a local Certificate Authority, installs it into the
#            System keychain, and issues a leaf cert signed by it. Because a
#            real CA signs it, curl and Safari trust it with NO flags. This is
#            what the spec is steering you toward and what keeps you off the
#            forbidden `-k`.
#
#   openssl  Fallback if mkcert is unavailable. Builds our own tiny CA by
#            hand — root key/cert, then a leaf CSR signed by it. Same trust
#            model, more steps.
#
# Either way the leaf certificate MUST carry a Subject Alternative Name.
# Modern curl and every browser ignore the Common Name entirely; a CN-only
# certificate produces "SSL: no alternative certificate subject name matches"
# and is the single most common reason teams give up and reach for -k, which
# scores zero on the HTTPS section.

source "$(dirname "$0")/../../../scripts/lib/common.sh"
load_env

# macOS ships LibreSSL 3.3.x at /usr/bin/openssl, which lacks `-ext` and some
# X.509v3 handling. Prefer Homebrew's real OpenSSL 3.x when it is present.
OPENSSL="$(command -v /opt/homebrew/opt/openssl@3/bin/openssl \
        || command -v /usr/local/opt/openssl@3/bin/openssl \
        || command -v openssl)"
[[ -n "$OPENSSL" ]] || die "No openssl found. Install with: brew install openssl@3"

# Portable SAN extraction: `-ext subjectAltName` is OpenSSL 1.1+ only, so fall
# back to parsing the full text dump, which every version supports.
san_of() {
  "$OPENSSL" x509 -in "$1" -noout -text 2>/dev/null \
    | awk '/Subject Alternative Name/{getline; gsub(/^[ \t]+/,""); print; exit}'
}

mkdir -p "$CERT_DIR"
CRT="$CERT_DIR/$APP_DOMAIN.crt"
KEY="$CERT_DIR/$APP_DOMAIN.key"

hdr "TLS certificate for $APP_DOMAIN"

if [[ -f "$CRT" && -f "$KEY" && "${FORCE:-0}" != "1" ]]; then
  warn "Certificate already exists at $CRT"
  "$OPENSSL" x509 -in "$CRT" -noout -subject -dates | sed 's/^/      /'
  confirm "Regenerate it?" || { info "Keeping existing certificate."; exit 0; }
fi

# ── Path 1: mkcert ──────────────────────────────────────────────────────────
if command -v mkcert >/dev/null 2>&1; then
  info "Using mkcert (local CA, trusted automatically)"

  # Idempotent: installs the CA into the System keychain if not already there.
  # Prompts for your password the first time only.
  mkcert -install

  mkcert -cert-file "$CRT" -key-file "$KEY" \
         "$APP_DOMAIN" "$API_DOMAIN" "$EDGE_IP" localhost 127.0.0.1

  CAROOT="$(mkcert -CAROOT)"
  cp "$CAROOT/rootCA.pem" "$CERT_DIR/rootCA.pem"

  ok "Certificate issued by the mkcert local CA"
  info "Root CA copied to $CERT_DIR/rootCA.pem"
  info "Copy that file to Mac 1, 3 and 4 and run: make client-trust"

# ── Path 2: OpenSSL, building a small CA by hand ────────────────────────────
else
  warn "mkcert not found — falling back to OpenSSL."
  warn "Install the nicer path with:  brew install mkcert nss"
  
  CA_KEY="$CERT_DIR/rootCA.key"
  CA_CRT="$CERT_DIR/rootCA.pem"

  # -- Root CA (created once, reused on regeneration) --
  if [[ ! -f "$CA_CRT" ]]; then
    info "Creating a local root CA…"
    "$OPENSSL" genrsa -out "$CA_KEY" 4096 2>/dev/null
    "$OPENSSL" req -x509 -new -nodes -key "$CA_KEY" -sha256 -days 825 \
      -out "$CA_CRT" \
      -subj "/C=IN/ST=Haryana/L=Sonipat/O=CN Phase 1 $TEAM/CN=$TEAM Local Root CA" \
      2>/dev/null
    ok "Root CA -> $CA_CRT"
  else
    ok "Reusing existing root CA"
  fi

  # -- Leaf certificate with SAN --
  # 825 days is the maximum lifetime Apple's platforms accept for a leaf
  # certificate; anything longer is rejected outright by Safari/curl on macOS.
  info "Creating leaf certificate with SAN…"
  EXT="$(mktemp)"
  cat > "$EXT" <<EXTEOF
basicConstraints       = CA:FALSE
keyUsage               = digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectAltName         = @alt_names

[alt_names]
DNS.1 = $APP_DOMAIN
DNS.2 = $API_DOMAIN
DNS.3 = localhost
IP.1  = $EDGE_IP
IP.2  = 127.0.0.1
EXTEOF

  "$OPENSSL" genrsa -out "$KEY" 2048 2>/dev/null
  "$OPENSSL" req -new -key "$KEY" -out "$CERT_DIR/leaf.csr" \
    -subj "/C=IN/ST=Haryana/L=Sonipat/O=CN Phase 1 $TEAM/CN=$APP_DOMAIN" 2>/dev/null
  "$OPENSSL" x509 -req -in "$CERT_DIR/leaf.csr" \
    -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$CRT" -days 825 -sha256 -extfile "$EXT" 2>/dev/null

  rm -f "$EXT" "$CERT_DIR/leaf.csr"
  ok "Leaf certificate -> $CRT"
  warn "Now run 'make client-trust' on EVERY Mac (including this one)."
fi

chmod 600 "$KEY"
chmod 644 "$CRT"

# ── Verify what we actually produced ────────────────────────────────────────
step "Certificate details"
"$OPENSSL" x509 -in "$CRT" -noout -subject -issuer -dates | sed 's/^/    /'

step "Subject Alternative Names (the part that matters)"
SAN="$(san_of "$CRT")"
echo "    ${SAN:-<none>}"

if [[ "$SAN" != *"DNS:$APP_DOMAIN"* ]]; then
  die "SAN does not include $APP_DOMAIN — curl will reject this cert and you would be forced to use -k."
fi
ok "SAN covers $APP_DOMAIN"

# The private key and the certificate must be a matching pair; if they are not,
# nginx starts fine and every TLS handshake fails with a confusing error.
# Compare the public key embedded in the certificate against the public half
# of the private key. Uses -pubkey/-pubout rather than -modulus, because
# LibreSSL (what /usr/bin/openssl is on macOS) has no `pkey -modulus`.
if [[ "$("$OPENSSL" x509 -in "$CRT" -noout -pubkey 2>/dev/null)" \
   == "$("$OPENSSL" pkey -in "$KEY" -pubout    2>/dev/null)" ]]; then
  ok "Key and certificate match"
else
  die "Key/certificate mismatch."
fi
echo
