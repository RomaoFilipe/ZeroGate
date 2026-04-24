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

## Policy Review Schedule

| Review | Frequency | Owner |
|---|---|---|
| Active user access audit | Monthly | Admin |
| Cloudflare Access policy review | Quarterly | Security |
| Contractor access revocation check | Monthly | Admin |
| Session log review | Weekly | Admin |
