#!/bin/bash
# ZeroGate Access — cloudflared ASG node bootstrap (v2.0)
# Installs cloudflared only. No Docker, no application services.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ── Install cloudflared ───────────────────────────────────────
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg

echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
  https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/cloudflared.list

apt-get update -q
apt-get install -y -q cloudflared awscli python3

# ── Fetch tunnel token from Secrets Manager ───────────────────
TOKEN=$(aws secretsmanager get-secret-value \
  --region "${aws_region}" \
  --secret-id "${secret_name}" \
  --query SecretString --output text \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['CF_TUNNEL_TOKEN'])")

# ── Install as systemd service ────────────────────────────────
cloudflared service install "$TOKEN"
systemctl enable cloudflared
systemctl start cloudflared

echo "cloudflared node ready — tunnel connector registered"
