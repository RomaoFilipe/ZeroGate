#!/bin/bash
# ============================================================
# ZeroGate Access Health Check
# Verifies all services are healthy and the tunnel is live.
# Exit code: 0 = all healthy, 1 = degraded/unhealthy
# Usage: ./scripts/health-check.sh [--json] [--quiet]
# ============================================================
set -euo pipefail

JSON_OUTPUT=false
QUIET=false
OVERALL_STATUS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)  JSON_OUTPUT=true; shift ;;
    --quiet) QUIET=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { [[ "${QUIET}" == "false" && "${JSON_OUTPUT}" == "false" ]] && echo -e "${GREEN}[OK]${NC}    $*"; }
fail() { [[ "${JSON_OUTPUT}" == "false" ]] && echo -e "${RED}[FAIL]${NC}  $*"; OVERALL_STATUS=1; }
warn() { [[ "${JSON_OUTPUT}" == "false" ]] && echo -e "${YELLOW}[WARN]${NC}  $*"; }

declare -A results=()

check_container() {
  local name="$1"
  local container="${2:-}"
  [[ -z "${container}" ]] && container="zerogate-${name}-1"

  local status
  status=$(docker inspect --format='{{.State.Health.Status}}' "${container}" 2>/dev/null || echo "not_found")

  case "${status}" in
    healthy)   ok "${name}: healthy"; results["${name}"]="healthy" ;;
    starting)  warn "${name}: still starting"; results["${name}"]="starting" ;;
    unhealthy) fail "${name}: UNHEALTHY"; results["${name}"]="unhealthy" ;;
    not_found) fail "${name}: container not found"; results["${name}"]="not_found" ;;
    *)         fail "${name}: unknown status (${status})"; results["${name}"]="${status}" ;;
  esac
}

check_http() {
  local name="$1"
  local url="$2"
  local expected="${3:-200}"

  local code
  code=$(docker run --rm --network zerogate-internal \
    curlimages/curl:8.10.1 -s -o /dev/null -w "%{http_code}" \
    --max-time 5 "${url}" 2>/dev/null || echo "000")

  if [[ "${code}" == "${expected}" || "${code}" == "301" || "${code}" == "302" ]]; then
    ok "${name}: HTTP ${code}"; results["${name}_http"]="ok"
  else
    fail "${name}: HTTP ${code} (expected ${expected})"; results["${name}_http"]="fail:${code}"
  fi
}

check_port() {
  local name="$1"
  local host="$2"
  local port="$3"

  if docker run --rm --network zerogate-internal \
    busybox nc -z -w 3 "${host}" "${port}" 2>/dev/null; then
    ok "${name}: port ${port} reachable"; results["${name}_port"]="ok"
  else
    fail "${name}: port ${port} NOT reachable"; results["${name}_port"]="fail"
  fi
}

check_zero_inbound_ports() {
  local open_ports
  open_ports=$(ss -tlnp 2>/dev/null | grep -v '127.0.0.1' | grep -v '::1' | tail -n +2 | wc -l)
  if [[ "${open_ports}" -eq 0 ]]; then
    ok "Zero inbound ports exposed on host"
    results["zero_ports"]="ok"
  else
    fail "Host has ${open_ports} ports listening on non-loopback addresses!"
    results["zero_ports"]="fail:${open_ports}"
    ss -tlnp 2>/dev/null | grep -v '127.0.0.1' | grep -v '::1' | tail -n +2
  fi
}

check_tunnel_connected() {
  local tunnel_status
  tunnel_status=$(docker exec zerogate-cloudflared-1 \
    cloudflared tunnel info 2>/dev/null | grep -c "HEALTHY" || echo "0")

  if [[ "${tunnel_status}" -gt 0 ]]; then
    ok "Cloudflare Tunnel: connected"
    results["tunnel"]="connected"
  else
    fail "Cloudflare Tunnel: NOT connected"
    results["tunnel"]="disconnected"
  fi
}

check_disk_space() {
  local usage
  usage=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
  if [[ "${usage}" -lt 80 ]]; then
    ok "Disk usage: ${usage}%"
    results["disk"]="ok:${usage}%"
  elif [[ "${usage}" -lt 90 ]]; then
    warn "Disk usage: ${usage}% — approaching limit"
    results["disk"]="warn:${usage}%"
  else
    fail "Disk usage: ${usage}% — CRITICAL"
    results["disk"]="critical:${usage}%"
    OVERALL_STATUS=1
  fi
}

[[ "${QUIET}" == "false" && "${JSON_OUTPUT}" == "false" ]] && echo "=== ZeroGate Access Health Check ==="

# Container health
check_container "authentik-db"
check_container "authentik-redis"
check_container "authentik-server"
check_container "authentik-worker"
check_container "guacamole-db"
check_container "guacd"
check_container "guacamole"
check_container "loki"
check_container "prometheus"
check_container "grafana"

# Internal HTTP endpoints
check_http "authentik-server"  "http://authentik-server:9000/-/health/ready/"
check_http "guacamole"         "http://guacamole:8080/guacamole/"
check_http "grafana"           "http://grafana:3000/api/health"
check_http "loki"              "http://loki:3100/ready"
check_http "prometheus"        "http://prometheus:9090/-/healthy"

# Network port checks
check_port "guacd"        "guacd"        "4822"

# Security checks
check_zero_inbound_ports
check_tunnel_connected
check_disk_space

if [[ "${JSON_OUTPUT}" == "true" ]]; then
  echo "{"
  echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"overall\": $([ ${OVERALL_STATUS} -eq 0 ] && echo '"healthy"' || echo '"unhealthy"'),"
  echo "  \"checks\": {"
  first=true
  for key in "${!results[@]}"; do
    [[ "${first}" == "false" ]] && echo ","
    echo -n "    \"${key}\": \"${results[$key]}\""
    first=false
  done
  echo ""
  echo "  }"
  echo "}"
fi

[[ "${QUIET}" == "false" && "${JSON_OUTPUT}" == "false" ]] && {
  echo ""
  if [[ "${OVERALL_STATUS}" -eq 0 ]]; then
    echo -e "${GREEN}All checks passed — ZeroGate Access is healthy${NC}"
  else
    echo -e "${RED}One or more checks failed — investigate above failures${NC}"
  fi
}

exit "${OVERALL_STATUS}"
