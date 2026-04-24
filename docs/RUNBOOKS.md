# ZeroGate Access — Runbooks

Operational procedures for common and emergency scenarios.
All commands assume you are in `/opt/zerogate/docker/` on the EC2 instance.

---

## 0. Connecting to the Server

**No SSH. No open ports. Use AWS SSM.**

```bash
# Interactive shell:
aws ssm start-session \
  --target <INSTANCE_ID> \
  --region eu-west-1

# Port forward (for local admin access):
aws ssm start-session \
  --target <INSTANCE_ID> \
  --region eu-west-1 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["9000"],"localPortNumber":["9000"]}'
# Then open: http://localhost:9000

# Get instance ID from Terraform:
cd infrastructure && terraform output instance_id
```

---

## 1. Day-to-Day Operations

### Check system status
```bash
./scripts/health-check.sh

# JSON output for automation:
./scripts/health-check.sh --json
```

### View live logs
```bash
cd /opt/zerogate/docker

# All services:
docker compose logs -f

# Specific service:
docker compose logs -f authentik-server
docker compose logs -f cloudflared
docker compose logs -f guacamole

# Last 100 lines:
docker compose logs --tail=100 authentik-server
```

### Check container resource usage
```bash
docker stats --no-stream
```

### Check tunnel status
```bash
docker exec zerogate-cloudflared-1 cloudflared tunnel info
```

---

## 2. Adding a New User

```bash
# 1. Create user in Authentik web UI:
#    (SSM port-forward to :9000, then http://localhost:9000)
#    Admin → Directory → Users → Create

# 2. Set user details:
#    Email: user@yourdomain.com
#    Name: Full Name
#    Password: (use password generator, min 14 chars)

# 3. Assign to groups:
#    Admin → Directory → Users → [user] → Groups tab
#    Add to: zerogate-users
#    Add to: remote-access (if they need Guacamole)
#    Add to: grafana-admin (if they need monitoring)

# 4. Send onboarding email (see docs/ONBOARDING.md for template)

# 5. User self-enrolls MFA on first login:
#    They visit: https://auth.yourdomain.com
#    They are prompted to set up TOTP on first login

# 6. Verify access appears in Grafana → Access Events dashboard
```

---

## 3. Revoking User Access (Immediate)

```bash
# Instant revocation — takes effect for ALL apps immediately:

# 1. Deactivate in Authentik:
#    Admin → Directory → Users → [user] → Deactivate
#    (or via Authentik API):
curl -X PATCH https://auth.yourdomain.com/api/v3/core/users/<user_id>/ \
  -H "Authorization: Bearer <api_token>" \
  -H "Content-Type: application/json" \
  -d '{"is_active": false}'

# 2. Revoke all sessions:
#    Admin → System → Tasks → Run: "Clear expired sessions"
#    Or: Admin → Events → Sessions → filter by user → Revoke all

# 3. Verify: no further events for this user in Grafana
```

---

## 4. Adding a New Resource to Guacamole

```bash
# Resources are managed in the Guacamole web UI:
# Access via SSM tunnel to :8080, then http://localhost:8080/guacamole

# SSH connection:
# Settings → Connections → New Connection
#   Name: App Server (Production)
#   Protocol: SSH
#   Hostname: app-server.internal (or IP)
#   Port: 22
#   Authentication: Private key (paste EC2 private key)
#   Max connections per user: 1

# RDP connection:
# Settings → Connections → New Connection
#   Name: Windows Server
#   Protocol: RDP
#   Hostname: windows.internal
#   Port: 3389
#   Domain: yourdomain.local
#   Security mode: NLA (recommended)
#   Ignore server cert: false (use valid cert)

# Assign connection to group (RBAC):
# Settings → Connection Groups → [group] → Edit → add connection
```

---

## 5. Rotating Secrets

```bash
# Dry run first — always:
./scripts/rotate-secrets.sh --dry-run --component all

# Rotate specific component:
./scripts/rotate-secrets.sh --component authentik
./scripts/rotate-secrets.sh --component guacamole
./scripts/rotate-secrets.sh --component grafana

# Rotate Cloudflare Tunnel (requires manual confirmation):
./scripts/rotate-secrets.sh --component tunnel

# Rotate everything (except tunnel):
./scripts/rotate-secrets.sh --component all
```

---

## 6. Taking a Backup

```bash
# Full backup (databases + configs + volumes):
./scripts/backup.sh

# Specific component:
./scripts/backup.sh --component databases
./scripts/backup.sh --component configs

# Verify backup landed in S3:
aws s3 ls s3://zerogate-backups-<ACCOUNT_ID>/ --recursive | tail -20
```

---

## 7. Restoring from Backup

### Restore Authentik database
```bash
# Stop Authentik services:
docker compose stop authentik-server authentik-worker

# Download backup:
aws s3 cp s3://zerogate-backups-<ACCOUNT>/databases/<date>/authentik-db-<timestamp>.sql.gz /tmp/

# Restore:
gunzip -c /tmp/authentik-db-<timestamp>.sql.gz \
  | docker exec -i zerogate-authentik-db-1 \
    psql -U authentik -d authentik

# Restart:
docker compose start authentik-server authentik-worker

# Verify:
docker compose logs --tail=50 authentik-server
```

### Restore Guacamole database
```bash
docker compose stop guacamole

aws s3 cp s3://zerogate-backups-<ACCOUNT>/databases/<date>/guacamole-db-<timestamp>.sql.gz /tmp/

gunzip -c /tmp/guacamole-db-<timestamp>.sql.gz \
  | docker exec -i zerogate-guacamole-db-1 \
    psql -U guacamole -d guacamole_db

docker compose start guacamole
```

---

## 8. Tunnel Disconnected

**Symptoms:** Users cannot reach any protected resource. Grafana shows tunnel health = DOWN.

```bash
# Check tunnel logs:
docker compose logs --tail=100 cloudflared

# Common causes and fixes:

# A) Token expired or rotated:
#    Run: ./scripts/rotate-secrets.sh --component tunnel

# B) Network connectivity from EC2:
ping 1.1.1.1          # Check outbound internet
curl -I https://cloudflare.com  # Check HTTPS outbound

# C) Restart tunnel:
docker compose restart cloudflared
docker compose logs -f cloudflared  # Watch for "CONNECTED"

# D) Credentials file missing/corrupt:
ls -la docker/cloudflared/credentials.json
# If missing: log into cloudflared and re-run tunnel create

# E) Cloudflare service disruption:
# Check: https://www.cloudflarestatus.com
```

---

## 9. Service Unhealthy / Container Crash Loop

```bash
# Identify the problem:
docker compose ps
docker compose logs --tail=200 <service>

# Restart single service:
docker compose restart <service>

# Force recreate (clears stuck state):
docker compose up -d --force-recreate <service>

# Nuclear: full stack restart (causes ~2 min downtime):
docker compose down && docker compose up -d

# If database is corrupt — restore from backup (see Runbook 7)

# Check disk space (common cause of crashes):
df -h
du -sh /var/lib/docker/volumes/*

# Check memory:
free -h
# If OOM: add swap (see ARCHITECTURE.md) or upgrade instance type
```

---

## 10. Running the Security Audit

```bash
# Before any production deployment:
./scripts/security-audit.sh

# Save a report:
./scripts/security-audit.sh --report /tmp/security-audit-$(date +%Y%m%d).txt

# Review critical fails and fix before going live
```

---

## 11. Complete Disaster Recovery

**RTO target: 2 hours from incident detection.**

```bash
# 1. Provision new infrastructure (from local machine with Terraform):
cd infrastructure
terraform apply -target=aws_instance.main -target=aws_eip.main

# 2. Get new instance ID:
terraform output instance_id

# 3. Bootstrap new instance:
aws ssm start-session --target <NEW_INSTANCE_ID> --region eu-west-1
# Inside SSM session:
git clone <your-repo> /opt/zerogate
cd /opt/zerogate
sudo ./scripts/bootstrap.sh

# 4. Restore databases:
./scripts/backup.sh  # Trigger restore (see Runbook 7 per component)

# 5. Update cloudflared config (same tunnel ID works on new instance):
cp docker/cloudflared/config.yml.example docker/cloudflared/config.yml
# Edit with correct tunnel ID + domain

# 6. Pull credentials from Secrets Manager:
# (bootstrap.sh does this — verify .env was created)
cat docker/.env | grep -c "CHANGE_ME"  # Should be 0

# 7. Start stack:
cd /opt/zerogate/docker
docker compose up -d

# 8. Verify:
./scripts/health-check.sh
./scripts/security-audit.sh

# 9. Test end-to-end:
# Open browser → navigate to https://access.yourdomain.com
# Full auth flow should work
```

---

## 12. Updating Service Versions

```bash
# 1. Review changelog for breaking changes
# 2. Backup:
./scripts/backup.sh

# 3. Edit docker-compose.yml — update image tag
# 4. Pull new image:
docker compose pull <service>

# 5. Recreate with new image:
docker compose up -d --no-deps <service>

# 6. Monitor:
docker compose logs -f <service>
./scripts/health-check.sh

# 7. If broken — rollback:
# Edit docker-compose.yml back to previous tag
docker compose up -d --no-deps <service>
```
