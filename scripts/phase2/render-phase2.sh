#!/usr/bin/env bash
# [any] Render every Phase 2 profile into infra/phase2/build/ — from the Phase 1
# templates plus infra/phase2/pf. Never writes Phase 1 output paths.

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

hdr "Rendering Phase 2 profiles for $TEAM"

TARGET="$(edge_target_ip)"
render_dns_profile primary "$TARGET"
render_dns_profile backup  "$TARGET"
render_standby_edge
render_pf

cat <<SUMMARY

  Phase 2 values
    Primary DNS   (Mac 1)  $DNS_IP
    Backup DNS             $BACKUP_DNS_IP        (Ext A)
    DNS TTL                ${P2_DNS_TTL}s                 (Ext B; Phase 1 uses $DNS_TTL)
    Records point at       $TARGET  -> $(edge_label "$TARGET")
    Primary edge  (Mac 2)  $EDGE_IP
    Standby edge           $STANDBY_EDGE_IP        (Ext E)
    Backend allow-list     $EDGE_IP, $STANDBY_EDGE_IP   (Ext C)

  Phase 1 files under infra/ were not touched.

SUMMARY
