#!/bin/bash
# ============================================================
# ZeroGate Threat Response — v1.1
# Queries Loki for auth failure events, extracts source IPs,
# and bans repeat offenders via the Cloudflare API.
#
# Runs every 5 minutes inside the threat-watcher container,
# or manually: ./scripts/threat-response.sh [--dry-run]
#
# Required env:
#   CF_API_TOKEN     — Cloudflare API token (Zone:Firewall:Edit)
#   CF_ACCOUNT_ID    — Cloudflare account ID
#   LOKI_URL         — Internal Loki URL (default: http://loki:3100)
#   BAN_THRESHOLD    — Failures before ban (default: 10)
#   WINDOW_MINUTES   — Lookback window in minutes (default: 10)
# ============================================================
set -euo pipefail

# ── Config ────────────────────────────────────────────────────
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
LOKI_URL="${LOKI_URL:-http://loki:3100}"
BAN_THRESHOLD="${BAN_THRESHOLD:-10}"
WINDOW_MINUTES="${WINDOW_MINUTES:-10}"
DRY_RUN=false
LOG_TAG="[threat-response]"

# ── CLI args ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Logging ───────────────────────────────────────────────────
log()  { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') ${LOG_TAG} INFO  $*"; }
warn() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') ${LOG_TAG} WARN  $*" >&2; }
die()  { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') ${LOG_TAG} ERROR $*" >&2; exit 1; }

# ── Guards ────────────────────────────────────────────────────
[[ -z "${CF_API_TOKEN}" ]]  && die "CF_API_TOKEN is not set"
[[ -z "${CF_ACCOUNT_ID}" ]] && die "CF_ACCOUNT_ID is not set"

# ── Query Loki for failed auth events ────────────────────────
# Authentik logs failed logins with event=login_failed.
# We query the last WINDOW_MINUTES of logs.

NOW_NS=$(date -u +%s%N)
START_NS=$(( ($(date -u +%s) - WINDOW_MINUTES * 60) * 1000000000 ))

LOKI_QUERY='{service="authentik-server"} |= "login_failed" | json'

log "Querying Loki for auth failures in last ${WINDOW_MINUTES}m..."

LOKI_RESPONSE=$(curl -sf \
  --max-time 15 \
  --get \
  --data-urlencode "query=${LOKI_QUERY}" \
  --data-urlencode "start=${START_NS}" \
  --data-urlencode "end=${NOW_NS}" \
  --data-urlencode "limit=5000" \
  "${LOKI_URL}/loki/api/v1/query_range" 2>/dev/null) || {
    warn "Failed to query Loki — skipping this cycle"
    exit 0
  }

# ── Extract IPs from log lines ────────────────────────────────
# Authentik logs include the client IP in several possible fields:
#   - "ip": "x.x.x.x"           (structured events)
#   - "client_ip": "x.x.x.x"    (request logs)
#   - "remote_ip": "x.x.x.x"    (older versions)
# We try all three patterns.

FAILED_IPS=$(echo "${LOKI_RESPONSE}" | jq -r '
  .data.result[]
  | .values[]
  | .[1]
  | (
      (try (fromjson | (.ip // .client_ip // .remote_ip // "")) catch "") +
      " " +
      (try (fromjson | (.request.remote_ip // "")) catch "")
    )
  | split(" ")[]
  | select(test("^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$"))
  | select(
      # Exclude private/loopback ranges
      test("^(127\\.|10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)") | not
    )
' 2>/dev/null || true)

if [[ -z "${FAILED_IPS}" ]]; then
  log "No external IPs found in failure logs — nothing to ban"
  exit 0
fi

# ── Count failures per IP ─────────────────────────────────────
declare -A IP_COUNT=()
while IFS= read -r ip; do
  [[ -z "${ip}" ]] && continue
  IP_COUNT["${ip}"]=$(( ${IP_COUNT["${ip}"]:-0} + 1 ))
done <<< "${FAILED_IPS}"

log "IPs with failures this window:"
for ip in "${!IP_COUNT[@]}"; do
  log "  ${ip}: ${IP_COUNT[$ip]} failures"
done

# ── Get existing bans (avoid duplicates) ──────────────────────
EXISTING_BANS=$(curl -sf \
  --max-time 15 \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/firewall/access_rules/rules?mode=block&configuration.target=ip&per_page=500" \
  2>/dev/null | jq -r '.result[].configuration.value' 2>/dev/null || true)

# ── Ban IPs over threshold ────────────────────────────────────
BANNED=0
SKIPPED=0

for ip in "${!IP_COUNT[@]}"; do
  count="${IP_COUNT[$ip]}"

  if [[ "${count}" -lt "${BAN_THRESHOLD}" ]]; then
    continue
  fi

  # Skip if already banned
  if echo "${EXISTING_BANS}" | grep -qF "${ip}"; then
    log "SKIP ${ip} — already banned (${count} failures)"
    (( SKIPPED++ )) || true
    continue
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY-RUN: would ban ${ip} (${count} failures in ${WINDOW_MINUTES}m)"
    continue
  fi

  log "BANNING ${ip} — ${count} failures in ${WINDOW_MINUTES}m (threshold: ${BAN_THRESHOLD})"

  BAN_RESPONSE=$(curl -sf \
    --max-time 15 \
    -X POST \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/firewall/access_rules/rules" \
    --data "$(jq -n \
      --arg ip "${ip}" \
      --arg note "Auto-banned by ZeroGate: ${count} auth failures in ${WINDOW_MINUTES}min at $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{mode:"block",configuration:{target:"ip",value:$ip},notes:$note}'
    )" 2>/dev/null)

  SUCCESS=$(echo "${BAN_RESPONSE}" | jq -r '.success' 2>/dev/null || echo "false")

  if [[ "${SUCCESS}" == "true" ]]; then
    RULE_ID=$(echo "${BAN_RESPONSE}" | jq -r '.result.id' 2>/dev/null || echo "unknown")
    log "BANNED ${ip} — rule_id=${RULE_ID}"
    (( BANNED++ )) || true
  else
    ERROR=$(echo "${BAN_RESPONSE}" | jq -r '.errors[0].message' 2>/dev/null || echo "unknown error")
    warn "Failed to ban ${ip}: ${ERROR}"
  fi
done

# ── Summary ───────────────────────────────────────────────────
log "Cycle complete — banned=${BANNED} skipped=${SKIPPED} threshold=${BAN_THRESHOLD} window=${WINDOW_MINUTES}m"
