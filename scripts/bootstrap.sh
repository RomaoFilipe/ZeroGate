#!/bin/bash
# ============================================================
# ZeroGate Access Bootstrap Script
# Run ONCE on a fresh EC2 instance after SSM connection.
# Usage: sudo ./scripts/bootstrap.sh
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN: $*${NC}"; }
die()  { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR: $*${NC}" >&2; exit 1; }

[[ "${EUID}" -ne 0 ]] && die "Run as root: sudo $0"

AWS_REGION="${AWS_REGION:-eu-west-1}"
PROJECT_DIR="/opt/zerogate"
COMPOSE_VERSION="2.29.7"
CLOUDFLARED_VERSION="2024.12.2"

# ============================================================
# 1. System update & baseline packages
# ============================================================
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  ca-certificates curl gnupg lsb-release \
  jq unzip git fail2ban ufw \
  htop ncdu net-tools \
  postgresql-client

# ============================================================
# 2. Docker
# ============================================================
if ! command -v docker &>/dev/null; then
  log "Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
else
  log "Docker already installed: $(docker --version)"
fi

# ============================================================
# 3. Docker Compose v2 plugin
# ============================================================
if ! docker compose version &>/dev/null; then
  log "Installing Docker Compose v2..."
  COMPOSE_URL="https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-x86_64"
  curl -fsSL "${COMPOSE_URL}" -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
else
  log "Docker Compose already installed: $(docker compose version)"
fi

# ============================================================
# 4. cloudflared
# ============================================================
if ! command -v cloudflared &>/dev/null; then
  log "Installing cloudflared ${CLOUDFLARED_VERSION}..."
  CF_URL="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64.deb"
  curl -fsSL "${CF_URL}" -o /tmp/cloudflared.deb
  dpkg -i /tmp/cloudflared.deb
  rm /tmp/cloudflared.deb
else
  log "cloudflared already installed: $(cloudflared --version)"
fi

# ============================================================
# 5. AWS CLI v2
# ============================================================
if ! command -v aws &>/dev/null; then
  log "Installing AWS CLI v2..."
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  cd /tmp && unzip -q awscliv2.zip && ./aws/install && cd -
  rm -rf /tmp/awscliv2.zip /tmp/aws
else
  log "AWS CLI already installed: $(aws --version)"
fi

# ============================================================
# 6. UFW — firewall: deny ALL inbound, allow all outbound
# ============================================================
log "Configuring UFW firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
# No inbound rules — outbound-only host
ufw --force enable
log "UFW status: $(ufw status | head -1)"

# Verify the EC2 security group also has zero inbound rules
SG_INBOUND=$(aws ec2 describe-security-groups \
  --region "${AWS_REGION}" \
  --filters "Name=tag:Project,Values=ZeroGate" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output text 2>/dev/null || echo "UNKNOWN")
if [[ "${SG_INBOUND}" == "None" || "${SG_INBOUND}" == "" ]]; then
  log "Security Group: ZERO inbound rules confirmed"
else
  warn "Security Group may have inbound rules: ${SG_INBOUND}"
fi

# ============================================================
# 7. fail2ban — brute force protection at OS level
# ============================================================
log "Configuring fail2ban..."
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled = false  # No SSH — using SSM only

[docker-auth]
enabled  = true
filter   = docker-auth
logpath  = /var/lib/docker/containers/*/*.log
maxretry = 5
bantime  = 7200
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# ============================================================
# 8. Docker daemon hardening
# ============================================================
log "Hardening Docker daemon..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "icc": false,
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 64000, "Soft": 64000 }
  }
}
EOF

systemctl enable docker
systemctl restart docker

# ============================================================
# 9. Pull secrets from AWS Secrets Manager
# ============================================================
log "Pulling secrets from AWS Secrets Manager..."

SECRET_NAME_PREFIX="zerogate-production"

pull_secret() {
  local secret_name="$1"
  local key="$2"
  aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "${secret_name}" \
    --query 'SecretString' \
    --output text | jq -r ".${key}"
}

# Create .env file from secrets
ENV_FILE="${PROJECT_DIR}/docker/.env"
mkdir -p "${PROJECT_DIR}/docker"

log "Writing ${ENV_FILE}..."
{
  echo "# Generated by bootstrap.sh at $(date -u) — DO NOT EDIT MANUALLY"
  echo "AUTHENTIK_SECRET_KEY=$(pull_secret "${SECRET_NAME_PREFIX}/authentik" AUTHENTIK_SECRET_KEY)"
  echo "AUTHENTIK_DB_PASSWORD=$(pull_secret "${SECRET_NAME_PREFIX}/authentik" AUTHENTIK_DB_PASSWORD)"
  echo "AUTHENTIK_REDIS_PASSWORD=$(pull_secret "${SECRET_NAME_PREFIX}/authentik" AUTHENTIK_REDIS_PASSWORD)"
  echo "GUACAMOLE_DB_PASSWORD=$(pull_secret "${SECRET_NAME_PREFIX}/guacamole" GUACAMOLE_DB_PASSWORD)"
  echo "GRAFANA_ADMIN_PASSWORD=$(pull_secret "${SECRET_NAME_PREFIX}/grafana" GRAFANA_ADMIN_PASSWORD)"
  echo "GRAFANA_SECRET_KEY=$(pull_secret "${SECRET_NAME_PREFIX}/grafana" GRAFANA_SECRET_KEY)"
  echo "CF_TUNNEL_TOKEN=$(pull_secret "${SECRET_NAME_PREFIX}/cloudflare" CF_TUNNEL_TOKEN)"
} > "${ENV_FILE}"

chmod 600 "${ENV_FILE}"
log "Secrets written to ${ENV_FILE}"

# ============================================================
# 10. Clone/update the project
# ============================================================
if [[ ! -d "${PROJECT_DIR}/.git" ]]; then
  warn "Project not cloned to ${PROJECT_DIR}."
  warn "Clone manually: git clone <your-repo> ${PROJECT_DIR}"
  warn "Then re-run this script or proceed manually."
fi

# ============================================================
# 11. Generate Guacamole init SQL
# ============================================================
INIT_SQL="${PROJECT_DIR}/docker/guacamole/init/initdb.sql"
if [[ ! -f "${INIT_SQL}" ]]; then
  log "Generating Guacamole PostgreSQL schema..."
  docker run --rm guacamole/guacamole:1.5.5 \
    /opt/guacamole/bin/initdb.sh --postgresql > "${INIT_SQL}"
  log "Schema written to ${INIT_SQL}"
fi

# ============================================================
# 12. Enable Docker auto-start on reboot
# ============================================================
log "Configuring Docker Compose systemd service..."
cat > /etc/systemd/system/zerogate.service <<EOF
[Unit]
Description=ZeroGate Access Docker Compose Stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${PROJECT_DIR}/docker
ExecStart=/usr/local/lib/docker/cli-plugins/docker-compose up -d --remove-orphans
ExecStop=/usr/local/lib/docker/cli-plugins/docker-compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zerogate.service

# ============================================================
log ""
log "Bootstrap complete!"
log ""
log "Next steps:"
log "  1. Copy your cloudflared config: cp docker/cloudflared/config.yml.example docker/cloudflared/config.yml"
log "  2. Fill in YOUR_TUNNEL_ID and YOUR_DOMAIN in config.yml"
log "  3. Copy cloudflared credentials: scp credentials.json ${PROJECT_DIR}/docker/cloudflared/"
log "  4. Start the stack: cd ${PROJECT_DIR}/docker && docker compose up -d"
log "  5. Monitor: docker compose logs -f"
log ""
log "Admin URLs (via SSM tunnel):"
log "  Authentik: http://localhost:9000/if/flow/initial-setup/"
log "  Guacamole: http://localhost:8080/guacamole/"
log "  Grafana:   http://localhost:3000/"
