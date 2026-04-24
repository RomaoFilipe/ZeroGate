#!/bin/bash
# EC2 user data — minimal bootstrap.
# Full setup is handled by scripts/bootstrap.sh after SSM connection.
set -euo pipefail

# Set hostname
hostnamectl set-hostname ${project_name}-server

# Configure unattended security upgrades
apt-get update -qq
apt-get install -y -qq unattended-upgrades apt-transport-https ca-certificates curl

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# Install AWS SSM Agent (usually pre-installed on Ubuntu AMIs — ensure it's running)
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# Install AWS CLI v2
if ! command -v aws &>/dev/null; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  cd /tmp && unzip -q awscliv2.zip && ./aws/install && cd -
fi

# Signal that userdata completed
echo "$(date -u) userdata complete — run scripts/bootstrap.sh for full setup" >> /var/log/zerogate-init.log
