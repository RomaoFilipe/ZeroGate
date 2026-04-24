#!/bin/bash
# ============================================================
# ZeroGate Secret Rotation
# Rotates one or all secrets and restarts affected services.
# Usage: ./scripts/rotate-secrets.sh [--component <name>] [--dry-run]
# Components: tunnel | authentik | guacamole | grafana | all
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN: $*${NC}"; }
info() { echo -e "${BLUE}[$(date '+%H:%M:%S')] $*${NC}"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR: $*${NC}" >&2; exit 1; }

AWS_REGION="${AWS_REGION:-eu-west-1}"
SECRET_PREFIX="${SECRET_PREFIX:-zerogate-production}"
PROJECT_DIR="${PROJECT_DIR:-/opt/zerogate}"
COMPOSE_DIR="${PROJECT_DIR}/docker"
DRY_RUN=false
COMPONENT="all"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
Options:
  --component <name>  Rotate specific component: tunnel|authentik|guacamole|grafana|all
  --dry-run           Show what would be done without making changes
  --region <region>   AWS region (default: eu-west-1)
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --component) COMPONENT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --region) AWS_REGION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

gen_secret() { openssl rand -hex "${1:-32}"; }
gen_password() { openssl rand -base64 36 | tr -dc 'A-Za-z0-9!#$%^&*' | head -c 48; }

update_secret() {
  local secret_id="$1"
  local key="$2"
  local new_value="$3"

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY-RUN] Would update ${secret_id} key=${key}"
    return
  fi

  # Fetch current secret, update the key, put new version
  local current
  current=$(aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "${secret_id}" \
    --query 'SecretString' --output text)

  local updated
  updated=$(echo "${current}" | jq --arg k "${key}" --arg v "${new_value}" '.[$k] = $v')

  aws secretsmanager put-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "${secret_id}" \
    --secret-string "${updated}"

  log "Updated ${secret_id}:${key}"
}

restart_service() {
  local service="$1"
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY-RUN] Would restart service: ${service}"
    return
  fi
  log "Restarting ${service}..."
  cd "${COMPOSE_DIR}"
  docker compose restart "${service}"
  sleep 5
  docker compose ps "${service}"
}

rotate_tunnel() {
  log "=== Rotating Cloudflare Tunnel ==="
  warn "This will create a new tunnel and delete the old one."
  read -r -p "Confirm rotation (yes/no): " confirm
  [[ "${confirm}" != "yes" ]] && { warn "Aborted."; return; }

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY-RUN] Would: cloudflared tunnel create zerogate-tunnel-new"
    info "[DRY-RUN] Would: update CF_TUNNEL_TOKEN in Secrets Manager"
    info "[DRY-RUN] Would: restart cloudflared container"
    info "[DRY-RUN] Would: delete old tunnel"
    return
  fi

  # Create new tunnel
  local tunnel_name="zerogate-tunnel-$(date +%Y%m%d)"
  cloudflared tunnel create "${tunnel_name}"

  local new_token
  new_token=$(cloudflared tunnel token "${tunnel_name}")

  update_secret "${SECRET_PREFIX}/cloudflare" "CF_TUNNEL_TOKEN" "${new_token}"

  # Update local .env
  sed -i "s|^CF_TUNNEL_TOKEN=.*|CF_TUNNEL_TOKEN=${new_token}|" "${COMPOSE_DIR}/.env"

  # Update cloudflared config to use new tunnel ID
  local new_tunnel_id
  new_tunnel_id=$(cloudflared tunnel list --output json | jq -r ".[] | select(.Name==\"${tunnel_name}\") | .ID")
  sed -i "s|^tunnel:.*|tunnel: ${new_tunnel_id}|" "${COMPOSE_DIR}/cloudflared/config.yml"

  restart_service "cloudflared"

  log "Tunnel rotated. Old tunnel cleanup:"
  warn "Manually delete the old tunnel: cloudflared tunnel delete <old-tunnel-name>"
  log "Rotation complete. Event logged."
}

rotate_authentik() {
  log "=== Rotating Authentik Secrets ==="

  local new_redis_pass
  new_redis_pass=$(gen_password)

  update_secret "${SECRET_PREFIX}/authentik" "AUTHENTIK_REDIS_PASSWORD" "${new_redis_pass}"

  if [[ "${DRY_RUN}" == "false" ]]; then
    sed -i "s|^AUTHENTIK_REDIS_PASSWORD=.*|AUTHENTIK_REDIS_PASSWORD=${new_redis_pass}|" "${COMPOSE_DIR}/.env"
    restart_service "authentik-redis"
    restart_service "authentik-server"
    restart_service "authentik-worker"
  fi

  warn "AUTHENTIK_SECRET_KEY rotation requires re-login for all users (sessions invalidated)."
  warn "Rotate AUTHENTIK_SECRET_KEY manually if required."
  log "Authentik rotation complete."
}

rotate_guacamole() {
  log "=== Rotating Guacamole DB Password ==="

  local new_pass
  new_pass=$(gen_password)

  update_secret "${SECRET_PREFIX}/guacamole" "GUACAMOLE_DB_PASSWORD" "${new_pass}"

  if [[ "${DRY_RUN}" == "false" ]]; then
    # Update PostgreSQL password
    docker exec zerogate-guacamole-db-1 \
      psql -U guacamole -c "ALTER USER guacamole PASSWORD '${new_pass}';"

    sed -i "s|^GUACAMOLE_DB_PASSWORD=.*|GUACAMOLE_DB_PASSWORD=${new_pass}|" "${COMPOSE_DIR}/.env"
    restart_service "guacamole"
  fi

  log "Guacamole rotation complete."
}

rotate_grafana() {
  log "=== Rotating Grafana Admin Password ==="

  local new_pass
  new_pass=$(gen_password)

  update_secret "${SECRET_PREFIX}/grafana" "GRAFANA_ADMIN_PASSWORD" "${new_pass}"

  if [[ "${DRY_RUN}" == "false" ]]; then
    docker exec zerogate-grafana-1 \
      grafana-cli admin reset-admin-password "${new_pass}"

    sed -i "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=${new_pass}|" "${COMPOSE_DIR}/.env"
  fi

  log "Grafana rotation complete."
  info "New Grafana admin password is in Secrets Manager: ${SECRET_PREFIX}/grafana"
}

log "ZeroGate Secret Rotation — component=${COMPONENT} dry-run=${DRY_RUN}"
[[ "${DRY_RUN}" == "true" ]] && warn "DRY-RUN mode — no changes will be made"

case "${COMPONENT}" in
  tunnel)    rotate_tunnel ;;
  authentik) rotate_authentik ;;
  guacamole) rotate_guacamole ;;
  grafana)   rotate_grafana ;;
  all)
    rotate_authentik
    rotate_guacamole
    rotate_grafana
    warn "Tunnel rotation requires separate manual step."
    ;;
  *) die "Unknown component: ${COMPONENT}. Use: tunnel|authentik|guacamole|grafana|all" ;;
esac

log "All rotations complete."
