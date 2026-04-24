# ============================================================
# ZeroGate — Makefile
# Convenience targets for common operations.
# Run from the project root: make <target>
# ============================================================

.PHONY: help init plan apply destroy \
        up down restart logs status \
        health audit backup rotate \
        guac-init tunnel-info \
        ssm ssm-tunnel

SHELL := /bin/bash
COMPOSE_DIR := docker
AWS_REGION  ?= eu-west-1

# Extract instance ID from Terraform outputs (requires Terraform state)
INSTANCE_ID := $(shell cd infrastructure && terraform output -raw instance_id 2>/dev/null || echo "")

# ── Help ─────────────────────────────────────────────────────
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' \
	  | sort

# ── Terraform ────────────────────────────────────────────────
init: ## Initialize Terraform
	cd infrastructure && terraform init

plan: ## Plan Terraform changes
	cd infrastructure && terraform plan -var-file=terraform.tfvars

apply: ## Apply Terraform changes (with confirmation)
	cd infrastructure && terraform apply -var-file=terraform.tfvars

destroy: ## Destroy all infrastructure (DANGEROUS — asks for confirmation)
	@echo "WARNING: This will destroy ALL ZeroGate infrastructure."
	@read -p "Type 'destroy' to confirm: " c && [[ "$$c" == "destroy" ]] || exit 1
	cd infrastructure && terraform destroy -var-file=terraform.tfvars

# ── Docker Compose ───────────────────────────────────────────
up: ## Start all services
	cd $(COMPOSE_DIR) && docker compose up -d

down: ## Stop all services
	cd $(COMPOSE_DIR) && docker compose down

restart: ## Restart all services
	cd $(COMPOSE_DIR) && docker compose restart

logs: ## Tail logs for all services (Ctrl+C to stop)
	cd $(COMPOSE_DIR) && docker compose logs -f --timestamps 2>&1 | grep -v healthcheck

logs-%: ## Tail logs for a specific service: make logs-authentik-server
	cd $(COMPOSE_DIR) && docker compose logs -f --timestamps $*

status: ## Show container status and resource usage
	@echo "=== Container Status ==="
	@cd $(COMPOSE_DIR) && docker compose ps
	@echo ""
	@echo "=== Resource Usage ==="
	@docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"

# ── Operations ───────────────────────────────────────────────
health: ## Run health check
	./scripts/health-check.sh

audit: ## Run security audit
	./scripts/security-audit.sh

backup: ## Run full backup to S3
	./scripts/backup.sh

rotate: ## Rotate all secrets (dry-run first — pass COMPONENT=tunnel|authentik|guacamole|grafana)
	./scripts/rotate-secrets.sh --dry-run --component $(or $(COMPONENT),all)
	@echo ""
	@read -p "Dry run complete. Run for real? (yes/no): " c && [[ "$$c" == "yes" ]] || exit 0
	./scripts/rotate-secrets.sh --component $(or $(COMPONENT),all)

update: ## Update service images with backup + health check (pass SERVICE=name or use --all)
	./scripts/update.sh $(if $(SERVICE),--service $(SERVICE),--all)

update-dry: ## Dry-run service update (shows what would change)
	./scripts/update.sh $(if $(SERVICE),--service $(SERVICE),--all) --dry-run

add-swap: ## Add 2 GB swap (recommended for t2.micro — run as root on EC2)
	sudo ./scripts/add-swap.sh $(or $(SIZE),2)

# ── Setup helpers ────────────────────────────────────────────
guac-init: ## Generate Guacamole PostgreSQL schema (run once before first deploy)
	bash $(COMPOSE_DIR)/guacamole/init/init.sh

tunnel-info: ## Show Cloudflare Tunnel status (run on EC2)
	docker exec zerogate-cloudflared-1 cloudflared tunnel info

setup-scripts: ## Make all scripts executable
	chmod +x scripts/*.sh
	chmod +x $(COMPOSE_DIR)/guacamole/init/init.sh

install-hooks: ## Install git pre-commit hook for secret scanning
	cp .github/hooks/pre-commit .git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit
	@echo "Pre-commit hook installed"

# ── AWS SSM ──────────────────────────────────────────────────
ssm: ## Open SSM shell session on EC2
	@[[ -n "$(INSTANCE_ID)" ]] || { echo "Cannot determine instance ID. Run: cd infrastructure && terraform output instance_id"; exit 1; }
	aws ssm start-session --target $(INSTANCE_ID) --region $(AWS_REGION)

ssm-tunnel-%: ## Forward a port via SSM: make ssm-tunnel-9000 (Authentik), ssm-tunnel-8080 (Guacamole), ssm-tunnel-3000 (Grafana)
	@[[ -n "$(INSTANCE_ID)" ]] || { echo "Cannot determine instance ID."; exit 1; }
	aws ssm start-session \
	  --target $(INSTANCE_ID) \
	  --region $(AWS_REGION) \
	  --document-name AWS-StartPortForwardingSession \
	  --parameters '{"portNumber":["$*"],"localPortNumber":["$*"]}'

# ── Validate environment ─────────────────────────────────────
check-env: ## Verify .env file has no placeholder values
	@echo "Checking for placeholder values in docker/.env..."
	@if grep -q "CHANGE_ME" $(COMPOSE_DIR)/.env 2>/dev/null; then \
	  echo "ERROR: Found CHANGE_ME placeholders in docker/.env — fill all values before deploying"; \
	  grep "CHANGE_ME" $(COMPOSE_DIR)/.env; \
	  exit 1; \
	else \
	  echo "OK — no placeholders found"; \
	fi

check-secrets: ## Verify no secrets are staged for git commit
	@echo "Scanning for accidentally staged secrets..."
	@git diff --cached --name-only 2>/dev/null | xargs -I{} sh -c \
	  'grep -lE "(password|secret|token|private_key)\s*=" "{}" 2>/dev/null && echo "WARNING: {} may contain secrets"' || true
	@echo "Scan complete."
