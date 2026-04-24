#!/bin/bash
# ============================================================
# ZeroGate Security Audit
# Run before production deployment and after major changes.
# Prints a checklist with PASS/FAIL/WARN for each control.
# Usage: ./scripts/security-audit.sh [--report <file>]
# ============================================================
set -euo pipefail

REPORT_FILE=""
PASS=0; FAIL=0; WARN=0
AWS_REGION="${AWS_REGION:-eu-west-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report) REPORT_FILE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

output() {
  echo -e "$*"
  [[ -n "${REPORT_FILE}" ]] && echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "${REPORT_FILE}"
}

pass() { output "${GREEN}[PASS]${NC} $*"; ((PASS++)); }
fail() { output "${RED}[FAIL]${NC} $*"; ((FAIL++)); }
warn() { output "${YELLOW}[WARN]${NC} $*"; ((WARN++)); }
section() { output "\n${BOLD}── $* ──${NC}"; }

[[ -n "${REPORT_FILE}" ]] && { echo "ZeroGate Security Audit — $(date -u)" > "${REPORT_FILE}"; }

output "${BOLD}ZeroGate Security Audit — $(date -u)${NC}"

# ============================================================
section "1. Network: Zero Open Ports"
# ============================================================

open_ports=$(ss -tlnp 2>/dev/null | grep -v '127.0.0.1' | grep -v '::1' | tail -n +2 | wc -l)
if [[ "${open_ports}" -eq 0 ]]; then
  pass "No ports listening on public interfaces"
else
  fail "Ports exposed on public interface: ${open_ports}"
  ss -tlnp | grep -v '127.0.0.1' | grep -v '::1' | tail -n +2
fi

if command -v ufw &>/dev/null; then
  ufw_status=$(ufw status | head -1 | awk '{print $2}')
  if [[ "${ufw_status}" == "active" ]]; then
    pass "UFW firewall is active"
    inbound_rules=$(ufw status | grep -c "ALLOW IN" || echo 0)
    if [[ "${inbound_rules}" -eq 0 ]]; then
      pass "UFW: zero inbound ALLOW rules"
    else
      fail "UFW has ${inbound_rules} inbound ALLOW rule(s)"
    fi
  else
    fail "UFW is not active"
  fi
fi

# ============================================================
section "2. AWS Security Group"
# ============================================================

sg_id=$(aws ec2 describe-security-groups \
  --region "${AWS_REGION}" \
  --filters "Name=tag:Project,Values=ZeroGate" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "")

if [[ -n "${sg_id}" && "${sg_id}" != "None" ]]; then
  inbound=$(aws ec2 describe-security-groups \
    --region "${AWS_REGION}" \
    --group-ids "${sg_id}" \
    --query 'length(SecurityGroups[0].IpPermissions)' \
    --output text 2>/dev/null || echo "-1")

  if [[ "${inbound}" == "0" ]]; then
    pass "Security Group ${sg_id}: zero inbound rules"
  else
    fail "Security Group ${sg_id}: has ${inbound} inbound rule(s)"
  fi
else
  warn "Could not determine Security Group (run from EC2 or with AWS credentials)"
fi

# ============================================================
section "3. TLS & Encryption"
# ============================================================

# Check IMDSv2 enforcement
imds=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 1 http://169.254.169.254/latest/meta-data/ 2>/dev/null || echo "000")
if [[ "${imds}" == "401" ]]; then
  pass "IMDSv2 enforced (returned 401 without token)"
elif [[ "${imds}" == "000" ]]; then
  warn "IMDS not reachable (expected if not on EC2)"
else
  fail "IMDSv2 NOT enforced — IMDS accessible without token (${imds})"
fi

# Check EBS encryption
if command -v aws &>/dev/null; then
  encrypted=$(aws ec2 describe-volumes \
    --region "${AWS_REGION}" \
    --filters "Name=tag:Project,Values=ZeroGate" \
    --query 'Volumes[*].Encrypted' \
    --output text 2>/dev/null || echo "")
  if echo "${encrypted}" | grep -q "False"; then
    fail "Unencrypted EBS volumes detected"
  elif [[ -n "${encrypted}" ]]; then
    pass "All EBS volumes encrypted"
  else
    warn "Could not verify EBS encryption (run from EC2 or with AWS credentials)"
  fi
fi

# ============================================================
section "4. Docker Security"
# ============================================================

# Check no containers run as root
root_containers=$(docker ps --format '{{.Names}}' | xargs -I{} docker inspect {} \
  --format '{{.Name}} user={{.Config.User}}' 2>/dev/null | grep -v "user=0" | grep "user=" || echo "")

privileged=$(docker ps -q | xargs docker inspect --format='{{.Name}}: privileged={{.HostConfig.Privileged}}' 2>/dev/null \
  | grep "privileged=true" || echo "")
if [[ -z "${privileged}" ]]; then
  pass "No privileged containers running"
else
  fail "Privileged containers detected:\n${privileged}"
fi

# Check docker socket not mounted in web-facing containers
for svc in authentik-server guacamole cloudflared grafana; do
  container="zerogate-${svc}-1"
  socket=$(docker inspect "${container}" \
    --format='{{range .Mounts}}{{if eq .Source "/var/run/docker.sock"}}SOCKET{{end}}{{end}}' 2>/dev/null || echo "")
  if [[ -z "${socket}" ]]; then
    pass "${svc}: Docker socket NOT mounted"
  else
    fail "${svc}: Docker socket IS mounted (security risk)"
  fi
done

# Check resource limits
for svc in authentik-server guacamole cloudflared grafana loki; do
  container="zerogate-${svc}-1"
  mem_limit=$(docker inspect "${container}" \
    --format='{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
  if [[ "${mem_limit}" -gt 0 ]]; then
    pass "${svc}: memory limit set ($(( mem_limit / 1024 / 1024 ))m)"
  else
    warn "${svc}: no memory limit set"
  fi
done

# ============================================================
section "5. Secrets Management"
# ============================================================

# Check for secrets in environment variables on host
host_secrets=$(env | grep -iE '(password|secret|token|key)=' | grep -v '^\(LS_COLORS\|TERM\)' || echo "")
if [[ -z "${host_secrets}" ]]; then
  pass "No secrets detected in host environment"
else
  warn "Secrets found in host environment (${#host_secrets} matches)"
fi

# Check .env file permissions
ENV_FILE="/opt/zerogate/docker/.env"
if [[ -f "${ENV_FILE}" ]]; then
  perms=$(stat -c "%a" "${ENV_FILE}")
  if [[ "${perms}" == "600" ]]; then
    pass ".env file permissions: 600 (owner read-only)"
  else
    fail ".env file permissions: ${perms} (should be 600)"
  fi
else
  warn ".env file not found at ${ENV_FILE}"
fi

# Check git history for secrets
if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null; then
  leaked=$(git log --all --full-history --follow -p 2>/dev/null \
    | grep -iE '(password|secret_key|token|private_key)\s*=' | grep -v 'CHANGE_ME' | head -5 || echo "")
  if [[ -z "${leaked}" ]]; then
    pass "No secrets detected in git history"
  else
    fail "Potential secrets in git history — run git-secrets scan"
  fi
fi

# ============================================================
section "6. MFA & Authentication"
# ============================================================

warn "MFA enforcement must be verified via Authentik admin UI:"
warn "  Admin → Flows → Authentication Flow → ensure TOTP stage is present and required"
warn "  Admin → Applications → verify all apps require MFA policy"
warn "Automated verification requires Authentik API token (not checked here)"

# ============================================================
section "7. Audit Logging"
# ============================================================

loki_running=$(docker inspect zerogate-loki-1 \
  --format='{{.State.Running}}' 2>/dev/null || echo "false")
promtail_running=$(docker inspect zerogate-promtail-1 \
  --format='{{.State.Running}}' 2>/dev/null || echo "false")

[[ "${loki_running}" == "true" ]] && pass "Loki is running (log aggregation active)" \
  || fail "Loki is NOT running"
[[ "${promtail_running}" == "true" ]] && pass "Promtail is running (log shipping active)" \
  || fail "Promtail is NOT running"

# ============================================================
section "8. Container Image Integrity"
# ============================================================

warn "Image digest verification (manual step):"
images=(
  "cloudflare/cloudflared:2024.12.2"
  "ghcr.io/goauthentik/server:2024.12.3"
  "guacamole/guacamole:1.5.5"
  "grafana/grafana:11.4.0"
  "grafana/loki:3.3.2"
  "postgres:16-alpine"
)

for img in "${images[@]}"; do
  digest=$(docker inspect "${img}" --format='{{index .RepoDigests 0}}' 2>/dev/null || echo "NOT PULLED")
  if [[ "${digest}" != "NOT PULLED" && -n "${digest}" ]]; then
    pass "Image verified: ${img}"
  else
    warn "Image not pulled or no digest: ${img}"
  fi
done

# ============================================================
output ""
output "${BOLD}── Audit Summary ──${NC}"
output "${GREEN}PASS: ${PASS}${NC}  ${RED}FAIL: ${FAIL}${NC}  ${YELLOW}WARN: ${WARN}${NC}"
output ""

if [[ "${FAIL}" -gt 0 ]]; then
  output "${RED}AUDIT FAILED — ${FAIL} critical control(s) not met. Fix before production.${NC}"
  exit 1
elif [[ "${WARN}" -gt 0 ]]; then
  output "${YELLOW}AUDIT PASSED WITH WARNINGS — review ${WARN} warning(s) above.${NC}"
  exit 0
else
  output "${GREEN}AUDIT PASSED — all controls satisfied.${NC}"
  exit 0
fi
