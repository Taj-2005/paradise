#!/usr/bin/env bash
# [client]  Collect the non-destructive Phase 2 evidence into evidence/phase2/.
# The demo scripts (failover, TTL watch, HA, cutover) write their own files
# while they run; this grabs the steady-state proof around them.

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env
is_edge && die "Run from a client (Mac 1, 3 or 4) — evidence must show the client's view."

hdr "Collecting Phase 2 evidence -> evidence/phase2/"

ev_open "A-backup-dns/A1-resolvers-and-both-servers.txt" "Ext A — client resolver list + both DNS servers answering"
ev_run "networksetup -getdnsservers '$NET_SERVICE'"
ev_run "scutil --dns | awk '/^resolver #1/{f=1} f&&/nameserver\\[/{print} /^resolver #2/{exit}'"
ev_run "dig @$DNS_IP $APP_DOMAIN +noall +answer +stats | grep -E '$APP_DOMAIN|SERVER'"
ev_run "dig @$BACKUP_DNS_IP $APP_DOMAIN +noall +answer +stats | grep -E '$APP_DOMAIN|SERVER'"
ev_close

ev_open "B-ttl/B1-ttl-in-answer.txt" "Ext B — TTL ${P2_DNS_TTL}s visible in the ANSWER section"
ev_run "dig $APP_DOMAIN | sed -n '/ANSWER SECTION/,/^\$/p'"
ev_note "Second column = TTL in seconds. Phase 1 served 0; Phase 2 serves ${P2_DNS_TTL}."
ev_close

ev_open "C-isolation/C1-direct-vs-edge.txt" "Ext C — direct backend access blocked, edge path works"
ev_run "curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --connect-timeout 3 http://$BACKEND_A_IP:$BACKEND_A_PORT/healthz"
ev_run "curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --connect-timeout 3 http://$BACKEND_B_IP:$BACKEND_B_PORT/healthz"
ev_run "curl -s -o /dev/null -w 'HTTP %{http_code} via edge\n' $APP_URL/api/status"
ev_note "Timeout (not 'refused') = packets dropped by pf: FILTERED, not CLOSED."
ev_close

ev_open "D-ha-failover/D1-steady-state-lb.txt" "Ext D — round robin across both backends (steady state)"
ev_run "for i in 1 2 3 4 5 6; do curl -s -D - -o /dev/null $APP_URL/api/status | grep -iE '^x-(backend|upstream-addr):' | tr -d '\r' | paste -sd' ' -; done"
ev_close

ev_open "E-edge-cutover/E1-standby-edge.txt" "Ext E — standby edge serves the same site, verified TLS, no -k"
ev_run "curl -sv --resolve $APP_DOMAIN:$HTTPS_PORT:$STANDBY_EDGE_IP https://$APP_DOMAIN:$HTTPS_PORT/api/status -o /dev/null 2>&1 | grep -E 'Connected to|SSL connection|verify ok|subject:|issuer:|^< HTTP|^< x-edge|^< x-backend'"
ev_close

ok "Done. Demo outputs are written by: make p2-demo-dns-failover · p2-ttl-watch · p2-ha-demo · p2-diagnose"
