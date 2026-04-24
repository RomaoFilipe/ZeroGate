#!/bin/bash
# ============================================================
# ZeroGate Backup Script
# Backs up: Authentik DB, Guacamole DB, all config files → S3
# Schedule: cron daily at 02:00 UTC
# Usage: ./scripts/backup.sh [--dry-run] [--component <name>]
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN: $*${NC}"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR: $*${NC}" >&2; exit 1; }

AWS_REGION="${AWS_REGION:-eu-west-1}"
S3_BUCKET="${BACKUP_S3_BUCKET:-}"
PROJECT_DIR="${PROJECT_DIR:-/opt/zerogate}"
COMPOSE_DIR="${PROJECT_DIR}/docker"
BACKUP_DIR="/tmp/zerogate-backup-$(date +%Y%m%d-%H%M%S)"
DRY_RUN=false
COMPONENT="all"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DATE_PATH=$(date +%Y/%m/%d)

[[ -z "${S3_BUCKET}" ]] && die "BACKUP_S3_BUCKET environment variable not set."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --component) COMPONENT="$2"; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

s3_upload() {
  local src="$1"
  local dest="$2"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would upload: ${src} → s3://${S3_BUCKET}/${dest}"
    return
  fi
  aws s3 cp "${src}" "s3://${S3_BUCKET}/${dest}" \
    --region "${AWS_REGION}" \
    --sse AES256 \
    --storage-class STANDARD_IA
  log "Uploaded → s3://${S3_BUCKET}/${dest}"
}

backup_postgres() {
  local container="$1"
  local db_user="$2"
  local db_name="$3"
  local label="$4"

  local dump_file="${BACKUP_DIR}/${label}-${TIMESTAMP}.sql.gz"

  log "Backing up ${label} database..."
  docker exec "${container}" \
    pg_dump -U "${db_user}" "${db_name}" \
    | gzip -9 > "${dump_file}"

  s3_upload "${dump_file}" "databases/${DATE_PATH}/${label}-${TIMESTAMP}.sql.gz"
  log "${label} backup: $(du -sh "${dump_file}" | cut -f1)"
}

backup_configs() {
  log "Backing up configuration files..."
  local config_archive="${BACKUP_DIR}/configs-${TIMESTAMP}.tar.gz"

  tar -czf "${config_archive}" \
    --exclude="${COMPOSE_DIR}/.env" \
    --exclude="${COMPOSE_DIR}/cloudflared/credentials.json" \
    -C "${PROJECT_DIR}" \
    docker/cloudflared/config.yml \
    docker/observability \
    docker/authentik/blueprints \
    infrastructure 2>/dev/null || true

  s3_upload "${config_archive}" "configs/${DATE_PATH}/configs-${TIMESTAMP}.tar.gz"
}

backup_volumes() {
  log "Backing up Docker named volumes (Authentik media)..."
  local media_archive="${BACKUP_DIR}/authentik-media-${TIMESTAMP}.tar.gz"

  docker run --rm \
    -v zerogate-authentik-media:/source:ro \
    -v "${BACKUP_DIR}":/backup \
    alpine tar czf "/backup/authentik-media-${TIMESTAMP}.tar.gz" -C /source .

  s3_upload "${media_archive}" "volumes/${DATE_PATH}/authentik-media-${TIMESTAMP}.tar.gz"
}

cleanup_old_backups() {
  log "Cleaning up backups older than 90 days in S3..."
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would delete S3 objects older than 90 days"
    return
  fi
  # S3 lifecycle policy handles this — but belt-and-suspenders:
  aws s3api list-objects-v2 \
    --bucket "${S3_BUCKET}" \
    --region "${AWS_REGION}" \
    --query "Contents[?LastModified<='$(date -d '90 days ago' +%Y-%m-%dT%H:%M:%S)'].Key" \
    --output text | tr '\t' '\n' | grep -v '^$' | while read -r key; do
      aws s3 rm "s3://${S3_BUCKET}/${key}" --region "${AWS_REGION}"
      log "Deleted old backup: ${key}"
    done
}

log "Starting ZeroGate backup — ${TIMESTAMP}"
mkdir -p "${BACKUP_DIR}"

case "${COMPONENT}" in
  databases)
    backup_postgres "zerogate-authentik-db-1"  "authentik"  "authentik"    "authentik-db"
    backup_postgres "zerogate-guacamole-db-1"  "guacamole"  "guacamole_db" "guacamole-db"
    ;;
  configs)
    backup_configs
    ;;
  volumes)
    backup_volumes
    ;;
  all)
    backup_postgres "zerogate-authentik-db-1"  "authentik"  "authentik"    "authentik-db"
    backup_postgres "zerogate-guacamole-db-1"  "guacamole"  "guacamole_db" "guacamole-db"
    backup_configs
    backup_volumes
    cleanup_old_backups
    ;;
  *) die "Unknown component: ${COMPONENT}" ;;
esac

# Cleanup local temp files
rm -rf "${BACKUP_DIR}"

log "Backup complete — all files in s3://${S3_BUCKET}/"

# Report to CloudWatch (optional — requires cloudwatch-agent or custom metric)
if command -v aws &>/dev/null; then
  aws cloudwatch put-metric-data \
    --region "${AWS_REGION}" \
    --namespace "ZeroGate/Backups" \
    --metric-name "BackupSuccess" \
    --value 1 \
    --unit Count 2>/dev/null || true
fi
