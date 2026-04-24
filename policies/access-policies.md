# ZeroGate — Cloudflare Access Policies

> Every application protected by ZeroGate must have an explicit policy.
> Default: **deny all**. Access is granted only by positive rule.

---

## Policy Naming Convention

```
<environment>-<application>-<team/role>
e.g.: prod-guacamole-devops
      prod-grafana-admin
      prod-authentik-self
```

---

## Application Policies

### 1. Authentik (auth.yourdomain.com)

**Purpose:** Identity Provider — all users must reach this to authenticate.

| Rule | Type | Value | Action |
|---|---|---|---|
| Allow Org Users | Email domain | `@yourdomain.com` | Allow |
| Require MFA | MFA method | TOTP or WebAuthn | Require |
| Block non-org | Everything else | — | Deny |

**Session duration:** 8 hours  
**Isolation:** None required (Authentik manages its own sessions)

```
Zero Trust → Access → Applications → Add Application
  Type: Self-hosted
  Domain: auth.yourdomain.com
  Session duration: 8h
  Policy: Allow emails ending @yourdomain.com + Require MFA
```

---

### 2. Remote Access / Guacamole (access.yourdomain.com)

**Purpose:** Browser-based SSH/RDP to internal resources.

| Rule | Type | Value | Action |
|---|---|---|---|
| Allow Remote-Access Group | Authentik group | `remote-access` | Allow |
| Require MFA | MFA method | TOTP or WebAuthn | Require |
| Block contractors by default | Email domain | `@contractor.com` | Deny (unless added to group) |

**Session duration:** 4 hours (shorter — high-value target)  
**Isolation:** Browser isolation recommended for contractors

```
Zero Trust → Access → Applications
  Type: Self-hosted
  Domain: access.yourdomain.com
  Session duration: 4h
  Identity provider: Authentik OIDC
  Policy:
    Rule 1 (Allow): Group = remote-access, MFA required
    Rule 2 (Deny): Everyone else
```

---

### 3. Grafana / Monitoring (monitor.yourdomain.com)

**Purpose:** Observability dashboards — restricted to ops/admin team.

| Rule | Type | Value | Action |
|---|---|---|---|
| Allow Grafana Admins | Authentik group | `grafana-admin` | Allow |
| Require MFA | MFA method | TOTP or WebAuthn | Require |
| Block everyone else | — | — | Deny |

**Session duration:** 8 hours  
**Country restriction:** Restrict to expected countries (e.g., Portugal, EU)

---

## Cloudflare Access Global Settings

```
Zero Trust → Settings → Authentication

Session lifetime:     8 hours (default)
Login page domain:    auth.yourdomain.com (custom)
CORS settings:        Disabled (not an API)
Browser isolation:    Enabled for contractor group
App launcher:         Enabled (shows user their authorized apps)
```

---

## Identity Provider Configuration (Authentik OIDC)

```
Zero Trust → Settings → Authentication → Add new identity provider
  Type: OpenID Connect (OIDC)
  Name: Authentik

  Issuer URL:          https://auth.yourdomain.com/application/o/cloudflare-access/
  Client ID:           <from Authentik application>
  Client Secret:       <from Authentik application>
  Auth URL:            https://auth.yourdomain.com/application/o/authorize/
  Token URL:           https://auth.yourdomain.com/application/o/token/
  Certificate:         Leave empty (JWKS endpoint used)
  Claims:
    Email claim:       email
    Groups claim:      groups
```

---

## Adding a New Protected Application

1. Deploy service on EC2 (Docker container on `zerogate-internal` network)
2. Add ingress rule to `docker/cloudflared/config.yml`:
   ```yaml
   - hostname: newapp.yourdomain.com
     service: http://newapp:PORT
   ```
3. Restart cloudflared: `docker compose restart cloudflared`
4. Create Cloudflare Access Application:
   - Zero Trust → Access → Applications → Add
   - Configure policy (see naming convention above)
5. Test: open browser → navigate to `newapp.yourdomain.com` → verify auth gate

---

---

## Geo-Blocking Policy (v1.1)

Managed by Terraform in `infrastructure/cloudflare.tf`. Applied at the Cloudflare edge — blocked countries never reach Authentik or the tunnel.

### Default Block List

| Country | Code | Reason |
|---|---|---|
| Russia | RU | High threat origin |
| China | CN | High threat origin |
| North Korea | KP | Sanctioned |
| Iran | IR | Sanctioned |
| Belarus | BY | Elevated threat |
| Syria | SY | Sanctioned |

### Enabling Geo-Blocking

```bash
# In infrastructure/terraform.tfvars:
enable_geo_blocking = true
block_countries     = ["RU", "CN", "KP", "IR", "BY", "SY"]

# Optional — strict mode (only allow specific countries)
allowed_countries_only = true
allowed_countries      = ["PT", "GB", "DE", "FR", "NL", "ES", "US", "IE"]

# Apply
make apply
```

### Whitelisting a Blocked Country

If a user legitimately connects from a blocked country (business travel, VPN):

1. Disable `allowed_countries_only` temporarily (or add the country to `allowed_countries`)
2. `make apply` — takes effect within 30 seconds at Cloudflare edge
3. Re-enable after the travel window

---

## Device Posture Policy (v1.1)

Device posture checks require the **Cloudflare WARP client** on the user's device. Checks are evaluated before Authentik authentication begins.

### Enabling Device Posture

```bash
# In infrastructure/terraform.tfvars:
enable_device_posture = true
cf_account_id         = "<your Cloudflare account ID>"

make apply
```

### Checks Enforced

| Check | Platform | Requirement |
|---|---|---|
| WARP client connected | All | WARP must be running |
| Disk encryption | Windows | BitLocker enabled |
| Disk encryption | macOS | FileVault enabled |
| OS version | Windows | ≥ 10.0.19044 (21H2) |
| OS version | macOS | ≥ 13.0.0 (Ventura) |

### WARP Client Installation (users)

```
1. Download Cloudflare WARP: https://1.1.1.1/
2. Install and open WARP
3. Sign in with your organisation account when prompted
4. WARP connects automatically on every network change
```

### Integrating Posture with Access Policies

After enabling device posture in Terraform, integrate with Cloudflare Access:

```
Zero Trust → Access → Applications → [your app] → Policies → Edit
  Add require rule:
    Selector: "Device Posture"
    Value: "ZeroGate — WARP Client Connected"
    Value: "ZeroGate — Disk Encryption (Windows)"
    Value: "ZeroGate — Disk Encryption (macOS)"
```

---

## Automated Threat Response Policy (v1.1)

The `threat-watcher` Docker service runs `scripts/threat-response.sh` every 5 minutes.

### How It Works

```
1. Query Loki for last 10 minutes of Authentik auth failures
2. Extract source IP from each failure log line
3. Count failures per IP
4. IPs with ≥ BAN_THRESHOLD failures → ban via Cloudflare API
5. Already-banned IPs are skipped (no duplicates)
6. All actions logged to stdout → captured by Loki/Promtail
```

### Tuning

| Variable | Default | Description |
|---|---|---|
| `THREAT_BAN_THRESHOLD` | `10` | Failures before ban |
| `THREAT_WINDOW_MINUTES` | `10` | Lookback window |

### Manual Operations

```bash
# Dry-run (see what would be banned without actually banning)
docker exec zerogate-threat-watcher-1 /scripts/threat-response.sh --dry-run

# View currently banned IPs
curl -s -H "Authorization: Bearer ${CF_API_TOKEN}" \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/firewall/access_rules/rules?mode=block" \
  | jq '.result[] | {ip: .configuration.value, note: .notes}'

# Unban an IP manually
# Zero Trust → Account → IP Access Rules → find IP → delete

# View threat-watcher logs
make logs-threat-watcher
```

---

## Policy Review Schedule

| Review | Frequency | Owner |
|---|---|---|
| Active user access audit | Monthly | Admin |
| Cloudflare Access policy review | Quarterly | Security |
| Contractor access revocation check | Monthly | Admin |
| Session log review | Weekly | Admin |
