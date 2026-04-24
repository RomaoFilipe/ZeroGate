# ZeroGate Access — Cloudflare Access Policies

> Every application protected by ZeroGate Access must have an explicit policy.
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

## SCIM Provisioning Policy (v1.2)

Managed by `docker/authentik/blueprints/zerogate-scim.yaml`.

### Endpoint

```
https://auth.yourdomain.com/source/scim/hr-scim/v2/
```

### Authentication

The HR system authenticates with a Bearer token:

```
1. Authentik Admin → Directory → Tokens → Create
2. Intent: API
3. Copy the token
4. Paste into your HR system as: Authorization: Bearer <token>
```

### What Gets Synced

| SCIM Object | Authentik Object | Matching |
|---|---|---|
| User | User | Email (link if exists, create if not) |
| Group | Group | Name (link if exists, create if not) |
| Department | Group | Via enterprise extension attribute |

### HR System Configuration

**Okta:**
```
SCIM Connector Base URL: https://auth.yourdomain.com/source/scim/hr-scim/v2
Authentication Mode: HTTP Header (Bearer)
Token: <generated above>
Supported SCIM Actions: Push Users, Push Groups
```

**Azure AD:**
```
Tenant URL: https://auth.yourdomain.com/source/scim/hr-scim/v2
Secret Token: <generated above>
Attribute Mapping: use defaults (email → email, displayName → name)
```

### New User Onboarding Flow

When a new user is pushed via SCIM:
1. Authentik account created automatically
2. User receives a password-setup email (Authentik invitation)
3. User sets their password and enrolls MFA on first login
4. Access groups are applied from the SCIM group push

---

## SAML 2.0 Federation Policy (v1.2)

Managed by `docker/authentik/blueprints/zerogate-saml.yaml`.

### SP (Authentik) Metadata

```
Metadata URL:   https://auth.yourdomain.com/source/saml/enterprise-idp/metadata/
ACS URL:        https://auth.yourdomain.com/source/saml/enterprise-idp/acs/
SLO URL:        https://auth.yourdomain.com/source/saml/enterprise-idp/slo/
Entity ID:      https://auth.yourdomain.com/source/saml/enterprise-idp/
Binding:        HTTP Redirect (AuthnRequest) + HTTP POST (ACS)
```

### Azure AD Configuration

```
1. Azure Portal → Azure AD → Enterprise Applications → New application → Create your own
2. Name: ZeroGate Access
3. Set up single sign-on → SAML
4. Basic SAML Configuration:
   Entity ID (Identifier):     https://auth.yourdomain.com/source/saml/enterprise-idp/
   Reply URL (ACS):            https://auth.yourdomain.com/source/saml/enterprise-idp/acs/
   Sign-on URL:                https://auth.yourdomain.com/if/flow/default-authentication-flow/
5. Attributes & Claims:
   email →     user.mail
   displayName → user.displayname
   groups →    group.id (or group.displayName for name-based matching)
6. Download Certificate (Base64) → import to Authentik as certificate
7. Copy:
   - Login URL → paste as sso_url in zerogate-saml.yaml
   - Azure AD Identifier → paste as issuer in zerogate-saml.yaml
```

### Okta Configuration

```
1. Okta Admin → Applications → Create App Integration → SAML 2.0
2. Single sign-on URL (ACS): https://auth.yourdomain.com/source/saml/enterprise-idp/acs/
3. Audience URI (SP Entity ID): https://auth.yourdomain.com/source/saml/enterprise-idp/
4. Attribute Statements:
   email →       user.email
   displayName → user.displayName
   groups →      Leave empty or use Group Attribute Statements
5. Download Okta certificate → import to Authentik
6. Copy Identity Provider SSO URL → sso_url in zerogate-saml.yaml
```

---

## Time-Based Access Policy (v1.2)

Managed by `docker/authentik/blueprints/zerogate-flows.yaml` (expression policy: `zerogate-business-hours`).

### Default Schedule

| Day | Access |
|---|---|
| Monday – Friday | 08:00 – 18:00 (Europe/Lisbon) |
| Saturday – Sunday | Denied |
| Public holidays | Not enforced (use manual group bypass) |

### Applying to a Flow

```
Authentik Admin → Flows → [your flow] → Policy / Group / User Bindings
→ Create Binding → Policy → zerogate-business-hours
→ Order: 0 (runs first)
→ Enable: true
→ Timeout: 30 (seconds)
```

### Changing the Schedule

Edit the expression directly in Authentik:
```
Admin → Policies → zerogate-business-hours → Edit expression
# Change TIMEZONE, BUSINESS_START, BUSINESS_END, or ALLOW_WEEKENDS
```

### Emergency Bypass (On-Call)

Add on-call engineers to the `business-hours-exempt` group. Bind this group **above** the time policy with a higher-priority allow rule:

```
Authentik Admin → [flow] → Bindings
  Binding 1 (order 0): Group = business-hours-exempt  → allow
  Binding 2 (order 10): Policy = zerogate-business-hours → deny outside hours
```

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
    Value: "ZeroGate Access — WARP Client Connected"
    Value: "ZeroGate Access — Disk Encryption (Windows)"
    Value: "ZeroGate Access — Disk Encryption (macOS)"
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
