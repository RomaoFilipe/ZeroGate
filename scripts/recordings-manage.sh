#!/bin/bash
# ============================================================
# Guacamole Session Recordings Manager (v1.2)
#
# Lists, archives, and purges session recordings stored in
# the guacamole-recordings Docker volume.
#
# Usage:
#   ./scripts/recordings-manage.sh list                    # list all recordings
#   ./scripts/recordings-manage.sh list --user alice       # filter by user
#   ./scripts/recordings-manage.sh archive --older-than 30 # archive + delete >30 days
#   ./scripts/recordings-manage.sh purge --older-than 90   # delete (no S3) >90 days
#   ./scripts/recordings-manage.sh export <filename>        # copy one recording locally
#
# Archive requires: BACKUP_S3_BUCKET in environment
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] $*${NC}"; }
info() { echo -e "${BLUE}[$(date '+%H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN: $*${NC}"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR: $*${NC}" >&2; exit 1; }

COMMAND="${1:-list}"
GUACD_CONTAINER="zerogate-guacd-1"
RECORDINGS_DIR="/recordings"
S3_BUCKET="${BACKUP_S3_BUCKET:-}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
OLDER_THAN=30
USER_FILTER=""
ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"

shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --older-than)  OLDER_THAN="$2"; shift 2 ;;
    --user)        USER_FILTER="$2"; shift 2 ;;
    *) break ;;
  esac
done

# Verify guacd is running
docker inspect "${GUACD_CONTAINER}" &>/dev/null || \
  die "guacd container '${GUACD_CONTAINER}' not running — run 'make up' first"

# ── Helpers ───────────────────────────────────────────────────
list_recordings() {
  local filter_arg=""
  [[ -n "${USER_FILTER}" ]] && filter_arg="-name '${USER_FILTER}-*'"

  info "Recordings in ${RECORDINGS_DIR}:"
  echo ""

  docker exec "${GUACD_CONTAINER}" sh -c "
    find ${RECORDINGS_DIR} -type f -name '*.guac' ${filter_arg} 2>/dev/null \
    | sort -r \
    | while read f; do
        size=\$(du -sh \"\$f\" 2>/dev/null | cut -f1)
        age=\$(( (\$(date +%s) - \$(stat -c %Y \"\$f\" 2>/dev/null || echo 0)) / 86400 ))
        echo \"  \${age}d  \${size}  \$(basename \$f)\"
      done
  " 2>/dev/null || echo "  (no recordings found)"

  echo ""
  TOTAL=$(docker exec "${GUACD_CONTAINER}" sh -c "
    find ${RECORDINGS_DIR} -type f -name '*.guac' 2>/dev/null | wc -l
  " 2>/dev/null || echo 0)
  TOTAL_SIZE=$(docker exec "${GUACD_CONTAINER}" sh -c "
    find ${RECORDINGS_DIR} -type f -name '*.guac' 2>/dev/null \
    | xargs du -sh 2>/dev/null | tail -1 | cut -f1
  " 2>/dev/null || echo "0")
  log "Total: ${TOTAL} recordings (${TOTAL_SIZE})"
}

archive_recordings() {
  [[ -z "${S3_BUCKET}" ]] && die "BACKUP_S3_BUCKET is not set — cannot archive"

  log "Archiving recordings older than ${OLDER_THAN} days to s3://${S3_BUCKET}/recordings/..."

  ARCHIVED=0
  FAILED=0

  while IFS= read -r filepath; do
    [[ -z "${filepath}" ]] && continue
    filename="$(basename "${filepath}")"
    s3_key="recordings/$(date -u '+%Y/%m')/${filename}"

    log "  Uploading ${filename}..."

    if [[ -n "${ENCRYPTION_KEY}" ]]; then
      # Encrypt with AES-256 before uploading
      docker exec "${GUACD_CONTAINER}" sh -c "
        cat '${filepath}' \
        | openssl enc -aes-256-cbc -pbkdf2 -k '${ENCRYPTION_KEY}' \
        | aws s3 cp - 's3://${S3_BUCKET}/${s3_key}.enc' \
          --region '${AWS_REGION}' \
          --sse AES256
      " 2>/dev/null && {
        docker exec "${GUACD_CONTAINER}" rm "${filepath}"
        (( ARCHIVED++ )) || true
      } || {
        warn "  Failed to archive ${filename}"
        (( FAILED++ )) || true
      }
    else
      docker exec "${GUACD_CONTAINER}" sh -c "
        aws s3 cp '${filepath}' 's3://${S3_BUCKET}/${s3_key}' \
          --region '${AWS_REGION}' \
          --sse AES256
      " 2>/dev/null && {
        docker exec "${GUACD_CONTAINER}" rm "${filepath}"
        (( ARCHIVED++ )) || true
      } || {
        warn "  Failed to archive ${filename}"
        (( FAILED++ )) || true
      }
    fi
  done < <(docker exec "${GUACD_CONTAINER}" sh -c "
    find ${RECORDINGS_DIR} -type f -name '*.guac' -mtime +${OLDER_THAN} 2>/dev/null
  " 2>/dev/null)

  log "Archive complete — archived=${ARCHIVED} failed=${FAILED}"
}

purge_recordings() {
  PURGE_COUNT=$(docker exec "${GUACD_CONTAINER}" sh -c "
    find ${RECORDINGS_DIR} -type f -name '*.guac' -mtime +${OLDER_THAN} 2>/dev/null | wc -l
  " 2>/dev/null || echo 0)

  if [[ "${PURGE_COUNT}" -eq 0 ]]; then
    log "No recordings older than ${OLDER_THAN} days to purge."
    return
  fi

  warn "About to permanently delete ${PURGE_COUNT} recordings older than ${OLDER_THAN} days."
  read -rp "Type 'purge' to confirm: " confirm
  [[ "${confirm}" != "purge" ]] && { log "Cancelled."; exit 0; }

  docker exec "${GUACD_CONTAINER}" sh -c "
    find ${RECORDINGS_DIR} -type f -name '*.guac' -mtime +${OLDER_THAN} -delete
  " 2>/dev/null

  log "Purged ${PURGE_COUNT} recordings."
}

export_recording() {
  local filename="$1"
  [[ -z "${filename}" ]] && die "Usage: recordings-manage.sh export <filename>"

  local dest="./${filename}"
  log "Exporting ${filename} to ${dest}..."

  docker cp "${GUACD_CONTAINER}:${RECORDINGS_DIR}/${filename}" "${dest}" 2>/dev/null || \
    die "Recording '${filename}' not found in container"

  log "Exported to ${dest}"
  log "Play with: guacenc -f mp4 ${dest}"
}

# ── Dispatch ──────────────────────────────────────────────────
case "${COMMAND}" in
  list)    list_recordings ;;
  archive) archive_recordings ;;
  purge)   purge_recordings ;;
  export)  export_recording "${1:-}" ;;
  *)       die "Unknown command: ${COMMAND}. Use: list | archive | purge | export" ;;
esac
