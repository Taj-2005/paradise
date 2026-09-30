#!/usr/bin/env bash
# Render every *.template into a real config, substituting {{VARS}} from .env.
#
# Why templates?  dnsmasq.conf and nginx.conf both need your LAN's real IPs.
# If those were committed directly, every teammate would edit them and git would
# fight. Instead: .env holds the values, templates hold the structure, this
# script joins them. Generated files are gitignored — regenerate, never edit.

source "$(dirname "$0")/lib/common.sh"
load_env

hdr "Rendering configs for $TEAM"

# Every {{PLACEHOLDER}} this script knows how to substitute.
VARS=(TEAM APP_DOMAIN API_DOMAIN DNS_IP EDGE_IP BACKEND_A_IP BACKEND_B_IP
      IFACE NET_SERVICE HTTP_PORT HTTPS_PORT BACKEND_A_PORT BACKEND_B_PORT
      DNS_TTL UPSTREAM_DNS CACHE_MAX_AGE CERT_DIR BREW_PREFIX)

render() {
  local tpl="$1" out="${1%.template}"
  local tmp; tmp="$(mktemp)"
  cp "$tpl" "$tmp"
  for v in "${VARS[@]}"; do
    # Using | as the sed delimiter because CERT_DIR contains slashes.
    LC_ALL=C sed -i '' "s|{{$v}}|${!v}|g" "$tmp"
  done

  # Fail loudly rather than shipping a config with a literal {{TYPO}} in it.
  if grep -q '{{[A-Z_]*}}' "$tmp"; then
    err "Unsubstituted placeholders in $tpl:"
    grep -o '{{[A-Z_]*}}' "$tmp" | sort -u | sed 's/^/      /' >&2
    rm -f "$tmp"; exit 1
  fi

  mv "$tmp" "$out"
  chmod 644 "$out"
  ok "${out#"$REPO_ROOT"/}"   # print repo-relative (BSD realpath has no --relative-to)
}

found=0
while IFS= read -r -d '' tpl; do
  render "$tpl"; found=$((found + 1))
done < <(find "$REPO_ROOT/infra" -name '*.template' -type f -print0 | sort -z)

(( found > 0 )) || die "No *.template files found under infra/"

cat <<SUMMARY

  Rendered $found file(s) using:
    TEAM          $TEAM
    APP_DOMAIN    $APP_DOMAIN  -> $EDGE_IP
    API_DOMAIN    $API_DOMAIN  -> $EDGE_IP
    DNS  (Mac 1)  $DNS_IP
    EDGE (Mac 2)  $EDGE_IP  :$HTTP_PORT/:$HTTPS_PORT
    A    (Mac 3)  $BACKEND_A_IP:$BACKEND_A_PORT
    B    (Mac 4)  $BACKEND_B_IP:$BACKEND_B_PORT
    Interface     $IFACE

SUMMARY
