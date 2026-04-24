# ZeroGate — User Onboarding

This document covers:
1. How to onboard a new user (admin steps)
2. What the user experiences on first login
3. Email templates

---

## Admin: Onboarding Checklist

```
[ ] 1. Create user account in Authentik
[ ] 2. Set a temporary password (user must change on first login)
[ ] 3. Assign to correct groups
[ ] 4. Send onboarding email (template below)
[ ] 5. Confirm user completed MFA enrollment
[ ] 6. Verify first access in Grafana dashboard
[ ] 7. Brief user on acceptable use
```

### Step 1 — Create user in Authentik

1. Connect via SSM tunnel: `aws ssm start-session --target <INSTANCE_ID>`
2. Forward port: `--document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["9000"],"localPortNumber":["9000"]}'`
3. Open: http://localhost:9000/
4. Navigate: **Admin → Directory → Users → Create**
5. Fill:
   - **Username:** `firstname.lastname`
   - **Name:** `First Last`
   - **Email:** `user@yourdomain.com`
   - **Password:** Generate with `openssl rand -base64 16` — user MUST change on first login
6. Click **Create**

### Step 2 — Assign Groups

Navigate to the user → **Groups** tab → Add:

| User type | Groups |
|---|---|
| Regular employee | `zerogate-users` |
| Needs remote access (SSH/RDP) | `zerogate-users`, `remote-access` |
| Operations/admin | `zerogate-users`, `remote-access`, `grafana-admin` |
| Contractor (time-limited) | `zerogate-users`, `remote-access` |

### Step 3 — For contractors: set account expiry

Navigate to user → **Edit** → **Attributes** tab:

```json
{
  "account_expiry": "2024-12-31T23:59:59Z"
}
```

Or use the Authentik expiry stage in a dedicated contractor flow.

---

## User Experience: First Login

### What the user sees:

1. **Email received** with portal URL and temporary password
2. **Navigate to:** `https://portal.yourdomain.com` (or `https://auth.yourdomain.com`)
3. **Login page:**
   - Enter username (email or username)
   - Enter temporary password
4. **Forced password change:** user sets a new password ≥ 14 chars with complexity
5. **MFA enrollment:**
   - User is shown a QR code
   - User scans with any TOTP app (Google Authenticator, Aegis, 1Password, Bitwarden)
   - User enters a 6-digit code to confirm enrollment
6. **Portal / App Launcher:** user sees their authorised applications
7. **Access resource:** click Guacamole → see their assigned connections

### Supported MFA apps

| App | Platform | Notes |
|---|---|---|
| Aegis | Android | Open source, recommended |
| Google Authenticator | iOS / Android | Simple, widely used |
| Microsoft Authenticator | iOS / Android | Supports push notifications |
| 1Password | All | Integrates with password manager |
| Bitwarden | All | Open source option |
| Hardware key (YubiKey) | Any | WebAuthn — most secure option |

---

## Onboarding Email Template

**Subject:** Your ZeroGate Access — Action Required

```
Hi [Name],

Your access to [Company] internal resources via ZeroGate has been set up.

────────────────────────────────────────
WHAT YOU GET ACCESS TO
────────────────────────────────────────
[List the specific resources/servers this user can access]

────────────────────────────────────────
HOW TO LOG IN (5 minutes)
────────────────────────────────────────

1. Open your browser and go to:
   https://auth.yourdomain.com

2. Log in with:
   Username: [username]
   Password: [temporary-password]

3. You will be asked to change your password.
   New password requirements:
   - Minimum 14 characters
   - At least 1 uppercase, 1 lowercase, 1 number, 1 symbol

4. Set up your MFA (mandatory):
   - You will see a QR code
   - Install any TOTP app on your phone:
     iOS/Android: Google Authenticator, Aegis, or 1Password
   - Scan the QR code and enter the 6-digit code to confirm

5. Done. You can now access your resources at:
   https://access.yourdomain.com

────────────────────────────────────────
IMPORTANT — SECURITY RULES
────────────────────────────────────────

✓ Do NOT share your password or MFA codes with anyone — ever.
✓ Do NOT store credentials in browsers on shared machines.
✓ Every session is logged: who accessed what, when, from where.
✓ Access is granted to specific resources only — you cannot
  access anything outside your authorised list.
✓ Sessions expire after 8 hours — you will need to log in again.

If you lose your MFA device: contact [admin@yourdomain.com] immediately.
If you suspect your account is compromised: contact us immediately.

────────────────────────────────────────

Questions? Contact: [admin@yourdomain.com]

[Your Name]
[Company] IT / Security
```

---

## Contractor Offboarding Checklist

When a contractor engagement ends:

```
[ ] Deactivate account in Authentik (Admin → Directory → Users → Deactivate)
[ ] Revoke all active sessions (Admin → Events → Sessions → Revoke for user)
[ ] Remove from all groups
[ ] Review access logs for the engagement period (Grafana → Access Events)
[ ] Remove any specific Guacamole connection permissions
[ ] Document offboarding date in your HR/ticketing system
```

**Verify zero access:** after deactivation, any attempt to access a protected resource should result in an Authentik login failure. Check the Grafana dashboard to confirm no further access events for the user.
