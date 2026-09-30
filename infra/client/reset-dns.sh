#!/usr/bin/env bash
# Restore this Mac's DNS to whatever it was before set-dns.sh ran.
# Also used by the spec §6.3 "wrong DNS server" failure demo to clean up.

source "$(dirname "$0")/../../scripts/lib/common.sh"
load_env

BACKUP="$REPO_ROOT/.dns-backup-$NET_SERVICE.txt"

hdr "Restore DNS for '$NET_SERVICE'"

if [[ -f "$BACKUP" ]]; then
  # networksetup takes the servers as separate arguments; "Empty" clears them
  # and hands control back to DHCP.
  # Portable read loop — `mapfile` is bash 4+, and macOS ships bash 3.2.
  servers=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && servers+=("$line")
  done < "$BACKUP"
  [[ ${#servers[@]} -gt 0 ]] || servers=(Empty)
  info "Restoring: ${servers[*]}"
  sudo networksetup -setdnsservers "$NET_SERVICE" "${servers[@]}"
  rm -f "$BACKUP"
else
  warn "No backup found — clearing to DHCP-provided DNS."
  sudo networksetup -setdnsservers "$NET_SERVICE" Empty
fi

sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder 2>/dev/null || true

step "Current setting"
networksetup -getdnsservers "$NET_SERVICE" | sed 's/^/    /'
ok "Restored."
