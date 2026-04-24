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

# ── v1.2: SCIM / SAML ───────────────────────────────────────
scim-apply: ## Apply SCIM provisioning blueprint to Authentik
	docker exec zerogate-authentik-worker-1 \
	  ak apply_blueprint /blueprints/zerogate-scim.yaml

saml-apply: ## Apply SAML federation blueprint to Authentik
	docker exec zerogate-authentik-worker-1 \
	  ak apply_blueprint /blueprints/zerogate-saml.yaml

saml-metadata: ## Print Authentik SP metadata URL for your IdP
	@echo "Give this URL to your enterprise IdP (Azure AD, Okta, etc.):"
	@echo "  SP Metadata:  https://auth.$$(grep '^DOMAIN=' docker/.env | cut -d= -f2)/source/saml/enterprise-idp/metadata/"
	@echo "  ACS URL:      https://auth.$$(grep '^DOMAIN=' docker/.env | cut -d= -f2)/source/saml/enterprise-idp/acs/"
	@echo "  Entity ID:    https://auth.$$(grep '^DOMAIN=' docker/.env | cut -d= -f2)/source/saml/enterprise-idp/"

# ── v1.2: Session Recording ──────────────────────────────────
recording-enable: ## Enable session recording on all Guacamole connections
	./scripts/guacamole-enable-recording.sh

recording-enable-dry: ## Dry-run recording enable (shows SQL only)
	./scripts/guacamole-enable-recording.sh --dry-run

recording-disable: ## Remove session recording from all connections
	./scripts/guacamole-enable-recording.sh --disable

recording-list: ## List all session recordings with size and age
	./scripts/recordings-manage.sh list

recording-list-%: ## Filter recordings by user: make recording-list-alice
	./scripts/recordings-manage.sh list --user $*

recording-archive: ## Archive recordings >30d to S3 and delete locally
	./scripts/recordings-manage.sh archive --older-than $(or $(DAYS),30)

recording-purge: ## Permanently delete recordings >90d (no S3 upload, asks for confirmation)
	./scripts/recordings-manage.sh purge --older-than $(or $(DAYS),90)

recording-export: ## Export a single recording file: make recording-export FILE=alice-server-20260101_120000.guac
	./scripts/recordings-manage.sh export $(FILE)

# ── v1.1: Threat Response ────────────────────────────────────
threat-dry-run: ## Dry-run threat response (shows what IPs would be banned)
	docker exec zerogate-threat-watcher-1 /scripts/threat-response.sh --dry-run

threat-run: ## Immediately run threat response (bans eligible IPs now)
	docker exec zerogate-threat-watcher-1 /scripts/threat-response.sh

threat-list-bans: ## List all IPs currently banned via Cloudflare API
	@[[ -n "$${CF_API_TOKEN:-}" ]] || { echo "Set CF_API_TOKEN in environment"; exit 1; }
	@[[ -n "$${CF_ACCOUNT_ID:-}" ]] || { echo "Set CF_ACCOUNT_ID in environment"; exit 1; }
	@curl -sf \
	  -H "Authorization: Bearer $${CF_API_TOKEN}" \
	  "https://api.cloudflare.com/client/v4/accounts/$${CF_ACCOUNT_ID}/firewall/access_rules/rules?mode=block&per_page=50" \
	  | jq -r '.result[] | "\(.configuration.value)\t\(.notes)"'

check-secrets: ## Verify no secrets are staged for git commit
	@echo "Scanning for accidentally staged secrets..."
	@git diff --cached --name-only 2>/dev/null | xargs -I{} sh -c \
	  'grep -lE "(password|secret|token|private_key)\s*=" "{}" 2>/dev/null && echo "WARNING: {} may contain secrets"' || true
	@echo "Scan complete."

# ── v2.0: High Availability ──────────────────────────────────
backend-init: ## Create S3 + DynamoDB Terraform remote state and migrate local state
	./scripts/init-backend.sh --region $(AWS_REGION)

backend-init-dry: ## Dry-run backend init (shows what would be created)
	./scripts/init-backend.sh --region $(AWS_REGION) --dry-run

ha-plan: ## Plan HA infrastructure (RDS + ASG)
	cd infrastructure && terraform plan \
	  -var-file=terraform.tfvars \
	  -var enable_rds=true \
	  -var enable_cloudflared_asg=true

ha-apply: ## Provision RDS Multi-AZ + cloudflared ASG
	cd infrastructure && terraform apply \
	  -var-file=terraform.tfvars \
	  -var enable_rds=true \
	  -var enable_cloudflared_asg=true

ha-guac-init: ## Initialise Guacamole schema on RDS (run once after ha-apply)
	@RDS_HOST=$$(cd infrastructure && terraform output -raw rds_guacamole_endpoint); \
	  GUAC_PASS=$$(aws secretsmanager get-secret-value \
	    --secret-id $$(cd infrastructure && terraform output -raw rds_secret_arn) \
	    --query SecretString --output text \
	    | python3 -c "import sys,json; print(json.load(sys.stdin)['GUACAMOLE_DB_PASSWORD'])"); \
	  docker run --rm guacamole/guacamole:1.5.5 \
	    /opt/guacamole/bin/initdb.sh --postgresql \
	  | PGPASSWORD="$$GUAC_PASS" psql \
	    -h "$$RDS_HOST" -U guacamole_user -d guacamole_db

ha-up: ## Start Docker Compose stack in HA mode (requires RDS + bootstrap.sh re-run)
	cd $(COMPOSE_DIR) && docker compose -f docker-compose.yml -f docker-compose.ha.yml up -d

ha-down: ## Stop HA stack
	cd $(COMPOSE_DIR) && docker compose -f docker-compose.yml -f docker-compose.ha.yml down

ha-status: ## Show running services in HA mode
	cd $(COMPOSE_DIR) && docker compose -f docker-compose.yml -f docker-compose.ha.yml ps

# ── v2.0: Disaster Recovery ──────────────────────────────────
dr-status: ## Show health of all HA components (RDS, ASG, EC2)
	./scripts/failover.sh --status

dr-failover: ## Trigger failover for a component: make dr-failover COMPONENT=rds-authentik
	@[[ -n "$(COMPONENT)" ]] || { echo "Usage: make dr-failover COMPONENT=rds-authentik|rds-guacamole|asg-refresh|ec2"; exit 1; }
	./scripts/failover.sh --component $(COMPONENT)

dr-failover-dry: ## Dry-run failover (shows action without executing)
	@[[ -n "$(COMPONENT)" ]] || { echo "Usage: make dr-failover-dry COMPONENT=rds-authentik"; exit 1; }
	./scripts/failover.sh --component $(COMPONENT) --dry-run

dr-asg-refresh: ## Rolling refresh of cloudflared ASG nodes (zero downtime)
	./scripts/failover.sh --component asg-refresh

dr-test: ## Run quarterly DR test procedure (RDS failover → health check → ASG refresh)
	@echo "=== ZeroGate Access DR Test — $$(date -u) ==="
	./scripts/failover.sh --status
	@echo ""
	@echo "--- Triggering RDS Authentik failover ---"
	./scripts/failover.sh --component rds-authentik
	@echo "Waiting 3 minutes for failover to complete..."
	@sleep 180
	@echo "--- Triggering RDS Guacamole failover ---"
	./scripts/failover.sh --component rds-guacamole
	@sleep 180
	@echo "--- Health check ---"
	./scripts/health-check.sh
	@echo "--- ASG rolling refresh ---"
	./scripts/failover.sh --component asg-refresh
	@echo "=== DR test complete. Log the result in docs/dr-test-log.txt ==="

# ── Local development ────────────────────────────────────────
local-up: ## Start stack for local testing (no cloudflared/CF credentials needed)
	@echo "→ A gerar schema do Guacamole..."
	@[[ -f $(COMPOSE_DIR)/guacamole/init/initdb.sql ]] || bash $(COMPOSE_DIR)/guacamole/init/init.sh
	cd $(COMPOSE_DIR) && docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
	@echo ""
	@echo "✓ Stack a arrancar. URLs locais:"
	@echo "  Authentik:  http://localhost:9000   (admin / Admin1234!local)"
	@echo "  Grafana:    http://localhost:3000   (admin / Admin1234!local)"
	@echo "  Guacamole:  http://localhost:8080/guacamole  (guacadmin / guacadmin)"
	@echo "  Prometheus: http://localhost:9090"
	@echo ""
	@echo "  make local-status  → ver estado dos containers"
	@echo "  make local-logs    → ver logs em tempo real"

local-down: ## Stop local test stack and remove containers
	cd $(COMPOSE_DIR) && docker compose -f docker-compose.yml -f docker-compose.local.yml down

local-clean: ## Stop stack and delete all volumes (reset to zero)
	cd $(COMPOSE_DIR) && docker compose -f docker-compose.yml -f docker-compose.local.yml down -v

local-status: ## Show container health for local stack
	cd $(COMPOSE_DIR) && docker compose -f docker-compose.yml -f docker-compose.local.yml ps

local-logs: ## Tail logs for local stack (Ctrl+C to stop)
	cd $(COMPOSE_DIR) && docker compose -f docker-compose.yml -f docker-compose.local.yml logs -f --timestamps 2>&1 | grep -v healthcheck

local-logs-%: ## Tail logs for a specific service: make local-logs-authentik-server
	cd $(COMPOSE_DIR) && docker compose -f docker-compose.yml -f docker-compose.local.yml logs -f --timestamps $*
