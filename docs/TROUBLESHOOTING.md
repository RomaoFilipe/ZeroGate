# ZeroGate Access — Troubleshooting

Quick-reference for the most common issues.

---

## Diagnosis Starting Point

```bash
# Always start here:
./scripts/health-check.sh

# Then look at logs for failing services:
docker compose logs --tail=100 <failing-service>

# Container states:
docker compose ps
```

---

## Authentication Issues

### "Access Denied" on Cloudflare page

**Symptom:** User sees a Cloudflare Access block page.
**Cause:** CF Access policy doesn't allow the user (wrong group, wrong email domain, missing MFA).

```
Check:
1. User is in the correct Authentik group (remote-access, etc.)
2. The Cloudflare Access policy includes the user's email or group
3. User has completed MFA enrollment in Authentik
4. CF Access session hasn't expired (check 8h session timeout)

Fix:
- Authentik Admin → Directory → Users → [user] → check Groups
- Cloudflare Dashboard → Zero Trust → Access → Policies → verify rule
```

### "502 Bad Gateway" from Cloudflare

**Symptom:** Cloudflare serves a 502 error.
**Cause:** cloudflared is running but the target service is down.

```bash
# Check which service is down:
./scripts/health-check.sh

# Check the target service:
docker compose logs --tail=50 authentik-server
docker compose logs --tail=50 guacamole

# Restart:
docker compose restart authentik-server

# If database is the issue:
docker compose logs --tail=50 authentik-db
docker compose restart authentik-db
```

### Authentik login page doesn't load

**Symptom:** `https://auth.yourdomain.com` returns error or doesn't load.

```bash
# 1. Is the tunnel connected?
docker compose logs --tail=20 cloudflared | grep -i "HEALTHY\|ERROR\|FAIL"

# 2. Is Authentik healthy?
docker compose logs --tail=50 authentik-server
# Look for: "Starting HTTP/WS server" or error stacktraces

# 3. Is the DB up?
docker compose logs --tail=20 authentik-db
# Look for: "ready to accept connections"

# Common fix: restart in order
docker compose restart authentik-db authentik-redis
sleep 10
docker compose restart authentik-server authentik-worker
```

### MFA not working (TOTP code rejected)

**Causes:**
1. Phone clock out of sync (TOTP is time-based)
2. User scanned wrong QR code
3. Using wrong authenticator app

```
Fix option 1: Sync phone clock
  iPhone: Settings → General → Date & Time → Set Automatically → ON
  Android: Settings → General → Date & Time → Automatic date & time → ON

Fix option 2: Re-enroll MFA
  Admin → Directory → Users → [user] → Authenticators tab → Delete TOTP → Save
  User next login will be prompted to re-enroll
```

### "Invalid redirect URI" on OIDC flow

**Symptom:** OIDC error during Cloudflare → Authentik redirect.

```
Check in Authentik:
  Admin → Applications → [app] → Provider → Redirect URIs
  Must exactly match the URL Cloudflare sends:
    For CF Access: leave this to Cloudflare's automatic handling
    For Guacamole: https://access.yourdomain.com/guacamole/
    For Grafana: https://monitor.yourdomain.com/login/generic_oauth

Common mistake: trailing slash mismatch, HTTP vs HTTPS
```

---

## Tunnel Issues

### Tunnel shows as disconnected in Cloudflare dashboard

```bash
# Check cloudflared container:
docker compose logs -f cloudflared

# Look for connection status lines, e.g.:
# "CONNECTED to ...", or "Connection failed"

# Common causes:
# 1. Token expired → rotate-secrets.sh --component tunnel
# 2. credentials.json missing or corrupt
ls -la docker/cloudflared/credentials.json  # Must exist and not be empty

# 3. Cloudflare edge unreachable:
docker exec zerogate-cloudflared-1 curl -sv https://cloudflare.com 2>&1 | head -20

# 4. Restart:
docker compose restart cloudflared

# 5. Check Cloudflare status:
curl -s https://www.cloudflarestatus.com/api/v2/summary.json | jq '.status.description'
```

### Tunnel connected but traffic not reaching service

```bash
# Check ingress rules in config.yml:
cat docker/cloudflared/config.yml

# Verify the hostname matches exactly what CF is sending:
# e.g., "access.yourdomain.com" not "access.yourdomain.com/"

# Check service is reachable on the Docker network:
docker exec zerogate-cloudflared-1 \
  curl -sv http://guacamole:8080/guacamole/ 2>&1 | head -20

# Reload cloudflared config (no restart needed):
docker exec zerogate-cloudflared-1 cloudflared tunnel reload
# Note: if cloudflared version doesn't support reload, restart instead
docker compose restart cloudflared
```

---

## Guacamole Issues

### Guacamole login redirects to Authentik but comes back with error

```bash
# Check OIDC configuration in guacamole container env:
docker inspect zerogate-guacamole-1 | jq '.[0].Config.Env' | grep OPENID

# Verify:
# OPENID_CLIENT_ID matches the application in Authentik
# OPENID_REDIRECT_URI exactly matches the Guacamole Authentik application's redirect URI
# OPENID_ISSUER matches: https://auth.yourdomain.com/application/o/guacamole/

# In Authentik:
# Admin → Applications → guacamole → Provider
# Check: Client ID, Redirect URIs, Issuer

# Force Guacamole to re-read config:
docker compose restart guacamole
```

### RDP/SSH session won't connect

```bash
# 1. Verify guacd is running:
docker compose logs --tail=20 guacd

# 2. Check guacd can reach the target host (from inside the container):
docker exec zerogate-guacd-1 nc -zv <target-host> <port>

# 3. For SSH: verify the private key format (must be PEM, not OpenSSH format for older Guacamole):
# Convert: ssh-keygen -p -m PEM -f your_key

# 4. For RDP: verify NLA is correctly configured
# RDP Target: allow "Network Level Authentication"
# In Guacamole connection: Security mode = NLA, Domain = correct value

# 5. Check Guacamole logs for the error:
docker compose logs --tail=100 guacamole | grep -i "error\|exception\|refused"
```

### Guacamole blank screen after connecting

```
Causes:
1. Display resolution too high for bandwidth → lower it in connection settings
2. RDP server not ready → wait 30s and retry
3. Audio/clipboard permissions causing hang → disable both in connection settings
4. Browser WebSocket blocked → check browser extensions (uBlock, etc.)

Fix: In Guacamole connection settings:
  - Display: 1280x800, colour depth 16-bit
  - Disable: audio, clipboard, file transfer (re-enable as needed)
  - Reconnect: restart the connection
```

---

## Database Issues

### PostgreSQL "role does not exist"

```bash
# This happens if the container was recreated without the init SQL
# Check if tables exist:
docker exec zerogate-guacamole-db-1 \
  psql -U guacamole -d guacamole_db -c "\dt"

# If empty — need to run init SQL:
cat docker/guacamole/init/initdb.sql | \
  docker exec -i zerogate-guacamole-db-1 \
  psql -U guacamole -d guacamole_db

# If initdb.sql doesn't exist, generate it:
./docker/guacamole/init/init.sh
```

### Database volume full

```bash
# Check volume size:
docker system df -v | grep postgres

# Check actual data size:
docker exec zerogate-authentik-db-1 \
  psql -U authentik -c "SELECT pg_size_pretty(pg_database_size('authentik'));"

# Authentik: clean up old events (keeps last 90 days by default — reduce if needed):
# Admin → Events → Settings → Event retention (days)

# If disk is full (emergency):
# 1. Stop non-essential services:
docker compose stop loki prometheus grafana
# 2. Free up Loki/Prometheus data if it's the culprit:
docker volume inspect zerogate-loki
```

---

## Observability Issues

### Grafana shows "No data" in dashboards

```bash
# 1. Verify Loki is receiving logs:
curl -s http://localhost:3100/loki/api/v1/labels 2>/dev/null || \
  docker exec zerogate-loki-1 wget -qO- http://localhost:3100/ready

# 2. Verify Promtail is shipping logs:
docker compose logs --tail=50 promtail | grep -i "error\|level=error"

# 3. Check Prometheus targets:
# SSM tunnel to :9090 → http://localhost:9090/targets
# All targets should show "UP"

# 4. Check Loki data source in Grafana:
# Grafana → Configuration → Data Sources → Loki → Test
# Should return: "Data source connected and labels found"
```

### Alerts not firing / not sending emails

```bash
# 1. Verify SMTP config in Grafana:
docker inspect zerogate-grafana-1 | jq '.[0].Config.Env' | grep SMTP

# 2. Test SMTP:
docker exec zerogate-grafana-1 \
  grafana-cli admin send-alert-notifications  # Grafana 10+

# 3. Check alert rules in Grafana:
# Grafana → Alerting → Alert Rules → check state (Normal/Pending/Firing)

# 4. Check contact points:
# Grafana → Alerting → Contact Points → Test (sends a test email)
```

---

## Emergency Commands

```bash
# Stop everything (maintenance mode):
cd /opt/zerogate/docker
docker compose down

# Start everything:
docker compose up -d

# View all container states:
docker compose ps -a

# Remove stuck container:
docker rm -f zerogate-<service>-1
docker compose up -d <service>

# Inspect container filesystem (debugging):
docker exec -it zerogate-<service>-1 sh

# Tail all logs at once with timestamps:
docker compose logs -f --timestamps 2>&1 | grep -v healthcheck
```
