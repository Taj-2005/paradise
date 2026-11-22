# CN Phase 2 — Harden, Recover & Troubleshoot. Included by the root Makefile.
# Run `make p2` for this list. Machine in brackets = where to run it.
#
# Target names start with "p2-" on purpose: the Phase 1 `make help` regex has
# no digits, so Phase 2 targets never clutter the Phase 1 help screen.

P2 := ./scripts/phase2
TO ?= standby
F  ?= list
WHAT ?= all
SECS ?=

.PHONY: p2 p2-render p2-test p2-verify p2-status p2-evidence \
        p2-primary-dns p2-backup-dns p2-client-dns p2-dns-stop p2-dns-start p2-demo-dns-failover \
        p2-ttl-watch p2-flush p2-cutover \
        p2-isolate p2-isolation-test \
        p2-health-watch p2-ha-demo \
        p2-standby-edge \
        p2-diagnose p2-fault p2-fault-undo \
        p2-rollback

p2: ## Phase 2 help
	@echo ""
	@echo "  CN Phase 2 — run these on the machine named in brackets"
	@echo ""
	@grep -E '^p2[a-zA-Z0-9_-]*:.*?## .*$$' $(MAKEFILE_LIST) \
	  | sed 's/^[^:]*phase2.mk://' \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ── Every machine ─────────────────────────────────────────────────────────────
p2-render: ## [any]      Render Phase 2 profiles -> infra/phase2/build/
	@$(P2)/render-phase2.sh
p2-test: ## [any]      Offline tests: syntax, rendering, parsers, Phase 1 untouched
	@$(P2)/test-phase2.sh
p2-status: ## [any]      Phase 2 state of THIS machine
	@$(P2)/status-phase2.sh
p2-rollback: ## [any]      Undo Phase 2 here (WHAT=all|primary-dns|backup-dns|client-dns|isolation|standby-edge|cutover|faults)
	@$(P2)/rollback.sh $(WHAT)

# ── Extension A — backup DNS ──────────────────────────────────────────────────
p2-backup-dns: ## [Mac 3]    Ext A: install + start the backup dnsmasq
	@$(P2)/install-backup-dns.sh
p2-client-dns: ## [clients]  Ext A: resolvers = Mac 1, then backup
	@$(P2)/client-dns.sh
p2-dns-stop: ## [Mac 1]    Ext A: stop dnsmasq (failover demo)
	@$(P2)/dns-service.sh stop
p2-dns-start: ## [Mac 1]    Ext A: start dnsmasq again
	@$(P2)/dns-service.sh start
p2-demo-dns-failover: ## [client]   Ext A: guided failover demo -> evidence
	@$(P2)/demo-dns-failover.sh

# ── Extension B — TTL ─────────────────────────────────────────────────────────
p2-primary-dns: ## [Mac 1]    Ext B: primary dnsmasq with TTL 30 (Phase 2 profile)
	@$(P2)/install-primary-dns.sh
p2-ttl-watch: ## [client]   Ext B/E: watch dig vs OS cache vs curl every 2s (SECS=120)
	@$(P2)/ttl-watch.sh $(SECS)
p2-flush: ## [client]   Ext B: flush the macOS DNS cache
	@$(P2)/flush-dns.sh
p2-cutover: ## [Mac 1+3]  Ext B/E: point records at TO=standby|primary
	@$(P2)/dns-cutover.sh $(TO)

# ── Extension C — service isolation ───────────────────────────────────────────
p2-isolate: ## [Mac 3, 4]  Ext C: pf — only the edges may reach :3001/:3002
	@$(P2)/install-isolation.sh
p2-isolation-test: ## [any]      Ext C: probe backend ports directly from here
	@$(P2)/isolation-test.sh

# ── Extension D — HA failover ─────────────────────────────────────────────────
p2-health-watch: ## [Mac 2]    Ext D: live backend health from the edge (read-only)
	@$(P2)/health-watch.sh
p2-ha-demo: ## [client]   Ext D: continuous traffic while Backend A dies + returns (SECS=60)
	@$(P2)/ha-demo.sh $(SECS)

# ── Extension E — edge migration ──────────────────────────────────────────────
p2-standby-edge: ## [Mac 4]    Ext E: standby nginx with the same config
	@$(P2)/install-standby-edge.sh

# ── Extension F — troubleshooting ─────────────────────────────────────────────
p2-diagnose: ## [client]   Ext F: top-down layer-by-layer diagnosis
	@$(P2)/diagnose.sh
p2-fault: ## [varies]   Ext F practice: inject F=<fault> (F=list to see them)
	@$(P2)/inject-fault.sh $(F)
p2-fault-undo: ## [varies]   Ext F practice: undo F=<fault>
	@$(P2)/inject-fault.sh $(F) undo

# ── Acceptance + evidence ─────────────────────────────────────────────────────
p2-verify: ## [client]   Phase 2 acceptance test (non-destructive)
	@$(P2)/verify-phase2.sh
p2-evidence: ## [client]   Collect steady-state Phase 2 evidence -> evidence/phase2/
	@$(P2)/collect-evidence.sh
