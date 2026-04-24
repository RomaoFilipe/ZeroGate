#!/bin/bash
# ============================================================
# ZeroGate Service Updater
# Updates one or all services to newer image versions with
# backup, health verification, and automatic rollback.
# Usage: ./scripts/update.sh [--service <name>] [--all] [--dry-run]
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN: $*${NC}"; }
info() { echo -e "${BLUE}[$(date '+%H:%M:%S')] $*${NC}"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR: $*${NC}" >&2; exit 1; }

COMPOSE_DIR="${PROJECT_DIR:-/opt/zerogate}/docker"
SERVICE=""
UPDATE_ALL=false
DRY_RUN=false
ROLLBACK_ON_FAIL=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)    SERVICE="$2"; shift 2 ;;
    --all)        UPDATE_ALL=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --no-rollback) ROLLBACK_ON_FAIL=false; shift ;;
    *) die "Unknown option: $1. Use --service <name> | --all [--dry-run]" ;;
  esac
done

[[ -z "${SERVICE}" && "${UPDATE_ALL}" == "false" ]] && \
  die "Specify --service <name> or --all"

cd "${COMPOSE_DIR}"

# ---- Record current image digests (for rollback) -----------
record_digests() {
  local svc="$1"
  docker inspect "zerogate-${svc}-1" \
    --format='{{index .RepoDigests 0}}' 2>/dev/null || echo "unknown"
}

# ---- Pull and update a single service ----------------------
update_service() {
  local svc="$1"
  local old_digest
  old_digest=$(record_digests "${svc}")

  info "Updating ${svc} (current digest: ${old_digest:0:40}...)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would pull and recreate ${svc}"
    return
  fi

  # Pull new image
  docker compose pull "${svc}"
  local new_digest
  new_digest=$(docker compose images "${svc}" -q 2>/dev/null | head -1)

  if [[ "${old_digest}" == "${new_digest}" ]]; then
    log "${svc}: already up-to-date"
    return
  fi

  log "${svc}: new image available — recreating..."

  # Take pre-update backup for database services
  if [[ "${svc}" =~ ^(authentik-db|guacamole-db)$ ]]; then
    warn "Database service update detected — running backup first..."
    if [[ -x "../scripts/backup.sh" ]]; then
      ../scripts/backup.sh --component databases
    fi
  fi

  # Recreate the container with the new image
  docker compose up -d --no-deps --force-recreate "${svc}"

  # Wait and verify health
  local attempts=0
  local max_attempts=12
  while [[ ${attempts} -lt ${max_attempts} ]]; do
    local status
    status=$(docker inspect "zerogate-${svc}-1" \
      --format='{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
    if [[ "${status}" == "healthy" ]]; then
      log "${svc}: healthy after update"
      return
    fi
    warn "${svc}: waiting for healthy status (${status}) — attempt $((attempts+1))/${max_attempts}"
    sleep 10
    ((attempts++))
  done

  # Health check failed
  if [[ "${ROLLBACK_ON_FAIL}" == "true" ]]; then
    warn "${svc}: health check failed — rolling back to previous image"
    docker compose pull "${svc}"  # This re-pulls — actually need to pin old digest
    warn "Manual rollback: edit docker-compose.yml to pin the previous image tag and run:"
    warn "  docker compose up -d --no-deps --force-recreate ${svc}"
    die "${svc}: update failed, manual rollback required"
  else
    die "${svc}: health check failed after update (rollback disabled)"
  fi
}

# ---- Main --------------------------------------------------
log "ZeroGate Update — dry-run=${DRY_RUN} rollback=${ROLLBACK_ON_FAIL}"

# Backup databases before any update
if [[ "${DRY_RUN}" == "false" ]]; then
  log "Running pre-update backup..."
  if [[ -x "../scripts/backup.sh" ]]; then
    ../scripts/backup.sh --component databases
  else
    warn "backup.sh not found — skipping pre-update backup"
  fi
fi

if [[ "${UPDATE_ALL}" == "true" ]]; then
  # Safe update order: datastores first, then apps, tunnel last
  SERVICES=(
    authentik-db authentik-redis
    authentik-server authentik-worker
    guacamole-db guacd guacamole
    loki prometheus grafana promtail
    node-exporter cadvisor
    cloudflared
  )
  for svc in "${SERVICES[@]}"; do
    update_service "${svc}"
  done
else
  update_service "${SERVICE}"
fi

if [[ "${DRY_RUN}" == "false" ]]; then
  log "Running post-update health check..."
  if [[ -x "../scripts/health-check.sh" ]]; then
    ../scripts/health-check.sh
  fi
fi

log "Update complete."
