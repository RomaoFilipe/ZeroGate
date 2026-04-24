#!/bin/bash
# ============================================================
# Guacamole Session Recording — Enable on All Connections (v1.2)
#
# Inserts recording parameters into the Guacamole PostgreSQL
# database for every existing connection that doesn't already
# have recording configured.
#
# Usage:
#   ./scripts/guacamole-enable-recording.sh [--dry-run] [--connection-id N]
#
# Options:
#   --dry-run           Show the SQL that would be run, don't execute
#   --connection-id N   Enable only for connection with this ID
#   --disable           Remove recording parameters from all connections
#
# After running, new sessions will be recorded to /recordings inside
# the guacd container (Docker volume: zerogate-guacamole-recordings).
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] $*${NC}"; }
info() { echo -e "${BLUE}[$(date '+%H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN: $*${NC}"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR: $*${NC}" >&2; exit 1; }

DRY_RUN=false
DISABLE=false
CONNECTION_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)         DRY_RUN=true; shift ;;
    --disable)         DISABLE=true; shift ;;
    --connection-id)   CONNECTION_FILTER="AND c.connection_id = $2"; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

CONTAINER="zerogate-guacamole-db-1"
DB_USER="${GUACAMOLE_DB_USER:-guacamole}"
DB_NAME="${GUACAMOLE_DB_NAME:-guacamole_db}"

run_sql() {
  local sql="$1"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "--- DRY RUN SQL ---"
    echo "${sql}"
    echo "-------------------"
    return
  fi
  docker exec -i "${CONTAINER}" \
    psql -U "${DB_USER}" -d "${DB_NAME}" -c "${sql}"
}

# ── List existing connections ─────────────────────────────────
info "Current connections in Guacamole:"
docker exec "${CONTAINER}" \
  psql -U "${DB_USER}" -d "${DB_NAME}" \
  -c "SELECT connection_id, connection_name, protocol FROM guacamole_connection ORDER BY connection_id;" \
  2>/dev/null || die "Cannot reach guacamole-db — is 'make up' running?"

echo ""

if [[ "${DISABLE}" == "true" ]]; then
  log "Removing recording parameters from all connections..."
  SQL_DISABLE="
    DELETE FROM guacamole_connection_parameter
    WHERE parameter_name IN (
      'recording-path',
      'recording-name',
      'recording-include-keys'
    );
  "
  run_sql "${SQL_DISABLE}"
  log "Recording disabled on all connections."
  exit 0
fi

# ── Enable recording on connections ──────────────────────────
# recording-name uses Guacamole substitution tokens:
#   ${GUAC_USERNAME}        — authenticated user
#   ${GUAC_CLIENT_HOSTNAME} — client hostname
#   ${GUAC_DATE}            — YYYYMMDD
#   ${GUAC_TIME}            — HHmmss

SQL_ENABLE="
BEGIN;

-- Insert recording-path where not already set
INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT
    c.connection_id,
    'recording-path',
    '/recordings'
FROM guacamole_connection c
WHERE NOT EXISTS (
    SELECT 1 FROM guacamole_connection_parameter p
    WHERE p.connection_id = c.connection_id
    AND   p.parameter_name = 'recording-path'
)
${CONNECTION_FILTER};

-- Insert recording-name where not already set
INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT
    c.connection_id,
    'recording-name',
    '\${GUAC_USERNAME}-\${GUAC_CLIENT_HOSTNAME}-\${GUAC_DATE}_\${GUAC_TIME}'
FROM guacamole_connection c
WHERE NOT EXISTS (
    SELECT 1 FROM guacamole_connection_parameter p
    WHERE p.connection_id = c.connection_id
    AND   p.parameter_name = 'recording-name'
)
${CONNECTION_FILTER};

-- Insert recording-include-keys where not already set
-- (records keystrokes — disable for compliance if needed)
INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT
    c.connection_id,
    'recording-include-keys',
    'true'
FROM guacamole_connection c
WHERE NOT EXISTS (
    SELECT 1 FROM guacamole_connection_parameter p
    WHERE p.connection_id = c.connection_id
    AND   p.parameter_name = 'recording-include-keys'
)
${CONNECTION_FILTER};

COMMIT;
"

log "Enabling session recording on all connections..."
run_sql "${SQL_ENABLE}"

if [[ "${DRY_RUN}" == "false" ]]; then
  log "Recording enabled. Verifying:"
  docker exec "${CONTAINER}" \
    psql -U "${DB_USER}" -d "${DB_NAME}" \
    -c "
      SELECT
        c.connection_name,
        c.protocol,
        p.parameter_name,
        p.parameter_value
      FROM guacamole_connection_parameter p
      JOIN guacamole_connection c USING (connection_id)
      WHERE p.parameter_name LIKE 'recording%'
      ORDER BY c.connection_name, p.parameter_name;
    "
  log "New sessions will be recorded to the guacamole-recordings volume."
  log "Use 'make recording-list' to view recordings."
fi
