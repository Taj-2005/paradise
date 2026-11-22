# ═══════════════════════════════════════════════════════════════════════════
#  CN Phase 2 · Extension C — Service isolation for {{BACKEND_LABEL}} (:{{BACKEND_PORT}})
#
#  Loaded into the pf anchor  com.apple/250.ParadiseIsolation  by
#  scripts/phase2/install-isolation.sh. macOS's stock /etc/pf.conf already
#  evaluates  anchor "com.apple/*",  so NO system file is edited and rollback
#  is a single  pfctl -a com.apple/250.ParadiseIsolation -F all.
#
#  Cloud equivalent: an AWS Security Group on the backend instances whose only
#  inbound rule is "TCP {{BACKEND_PORT}} from the ALB's security group".
#
#  pf evaluates top to bottom; `quick` stops at the first match. Order matters.
# ═══════════════════════════════════════════════════════════════════════════

# 1. Never filter loopback — a process talking to itself (the backend's own
#    health checks, or the standby nginx on this same Mac) is not a client.
pass in quick on lo0 all

# 2. The edges may open TCP connections to the backend port.
#    {{EDGE_IP}}         = primary edge (Mac 2, nginx)
#    {{STANDBY_EDGE_IP}} = standby edge (Extension E) — must reach the backends
#                          too, or a DNS cutover would land on an edge that 502s.
#    `keep state` lets the replies flow back without a separate outbound rule.
pass in quick proto tcp from { {{EDGE_IP}}, {{STANDBY_EDGE_IP}} } to any port {{BACKEND_PORT}} keep state

# 3. Everyone else: DROP — silently discard the SYN.
#    `drop` (not `return`) is a deliberate teaching choice:
#      drop   -> client sees "Operation timed out"   = FILTERED (a firewall)
#      return -> client sees "Connection refused"    = looks like CLOSED (no listener)
#    Phase 1's wrong-port demo produces "refused"; this produces a timeout, so
#    the two failures are distinguishable on screen and in Wireshark
#    (SYN, SYN retransmit, SYN retransmit … and never a SYN-ACK or RST).
block drop in quick proto tcp from any to any port {{BACKEND_PORT}}
