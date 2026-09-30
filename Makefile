# CN Phase 1 — task runner.
# Every target is safe to re-run. Run `make` with no args for help.

SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help render dns edge backend-a backend-b client-dns client-trust \
        preflight verify lb evidence capture demo-fail restore status smoke bootstrap \
        diagrams

help: ## Show this help
	@echo ""
	@echo "  CN Phase 1 — run these on the machine named in brackets"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""

render: ## [any]    Regenerate dnsmasq.conf + nginx confs from .env
	@./scripts/render-configs.sh

dns: render ## [Mac 1]  Install + start dnsmasq
	@./infra/mac1-dns/install.sh

edge: render ## [Mac 2]  Generate certs, install nginx config, start nginx
	@./infra/mac2-edge/scripts/install.sh

backend-a: ## [Mac 3]  Start Backend A on :3001
	@./infra/mac3-backend-a/run.sh

backend-b: ## [Mac 4]  Start Backend B on :3002
	@./infra/mac4-backend-b/run.sh

client-dns: ## [Mac 2/3/4] Point this machine's resolver at Mac 1
	@./infra/client/set-dns.sh

client-trust: ## [all]    Install the local CA into this Mac's System keychain
	@./infra/client/trust-ca.sh

diagrams: ## [any]    Re-render docs/diagrams/*.mmd and refresh index.html
	@./scripts/build-diagrams.sh
	@./scripts/inline-diagrams.sh

bootstrap: ## [any]    First-run setup — detects this machine's role
	@./scripts/bootstrap.sh

smoke: ## [one mac] Full stack on ONE laptop — validate before you need 4
	@./scripts/smoke-local.sh

preflight: ## [any]    Ping matrix + port reachability across all 4 machines
	@./scripts/preflight.sh

verify: ## [client]  Run every Phase 1 acceptance check (the big one)
	@./scripts/verify-all.sh

lb: ## [client]  6 consecutive requests, assert both backends answer
	@./scripts/lb-check.sh

evidence: ## [client]  Collect every required output into evidence/
	@./scripts/collect-evidence.sh

capture: ## [any]    tcpdump helper -> evidence/captures/
	@./scripts/capture.sh

demo-fail: ## [any]    Interactive failure-demonstration menu (spec 6.3)
	@./scripts/failure-demo.sh

restore: ## [any]    Return this machine to the known-good state
	@./scripts/restore.sh

status: ## [any]    Show what is running on this machine
	@./scripts/status.sh
