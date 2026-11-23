#!/usr/bin/env bash
# [client]  Extension B — flush the macOS resolver cache and show the fresh answer.

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

hdr "Flush the client DNS cache"
info "before: OS cache says $APP_DOMAIN -> $(os_cache_ip "$APP_DOMAIN")"
flush_client_dns
ok "dscacheutil -flushcache + killall -HUP mDNSResponder"
info "after:  OS cache says $APP_DOMAIN -> $(os_cache_ip "$APP_DOMAIN")   (fresh lookup)"
