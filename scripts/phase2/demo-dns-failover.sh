#!/usr/bin/env bash
# [client — Mac 3 recommended: it is neither DNS server]  Extension A — guided backup-DNS failover demo.
#
# Proves: (1) clients list two resolvers, (2) with the primary stopped they keep
# resolving through the backup, (3) a DNS failure and an application failure
# look different and are diagnosed at different layers.

source "$(dirname "$0")/lib/p2common.sh"
load_p2_env

ev_open "A-backup-dns/A-failover-demo.txt" "Extension A — backup DNS failover"
hdr "Extension A — backup DNS failover"

step "1 · BEFORE: this client lists both resolvers, primary first"
ev_run "networksetup -getdnsservers '$NET_SERVICE'"
ev_run "scutil --dns | awk '/^resolver #1/{f=1} f&&/nameserver\\[/{print} /^resolver #2/{exit}'"
ev_run "dig $APP_DOMAIN | grep -E 'ANSWER SECTION' -A1; dig $APP_DOMAIN | grep SERVER"
ev_note "→ answered by the PRIMARY ($DNS_IP)."

ev_pause "On Mac 1 ($DNS_IP) run:  make p2-dns-stop"

step "2 · DURING: primary is down"
ev_run "dig +time=2 +tries=1 @$DNS_IP $APP_DOMAIN | grep -E 'connection refused|timed out|no servers|status' || true"
ev_note "→ the primary no longer answers."
flush_client_dns
ev_note "(client DNS cache flushed, so the next lookup is a real one, not a cached hit)"
ev_run "dig $APP_DOMAIN | grep -E 'communications error|ANSWER SECTION|SERVER' -A1"
ev_note "→ dig hit an error on $DNS_IP and fell through to the BACKUP ($BACKUP_DNS_IP)."
ev_run "curl -s -o /dev/null -w 'HTTP %{http_code} via %{remote_ip}  (name resolved by the backup)\n' $APP_URL/api/status"

step "3 · CONTRAST: DNS failure vs application failure"
ev_note "DNS service failure  : name resolution stops ('Could not resolve host'), but"
ev_note "                       ping $EDGE_IP still works — the IP layer is fine."
ev_note "Application failure  : resolution WORKS (dig returns $EDGE_IP), TCP+TLS to the"
ev_note "                       edge WORK, but nginx returns 502 — the backend is down."
ev_note "Different first-failing layer → different fix. That is the diagnosis skill."
ev_run "ping -c2 -t3 $EDGE_IP | tail -2"

ev_pause "On Mac 1 run:  make p2-dns-start     (restore the primary)"

step "4 · AFTER: primary restored"
flush_client_dns
ev_run "dig $APP_DOMAIN | grep SERVER"
ev_note "→ back on the primary ($DNS_IP)."
ev_close
