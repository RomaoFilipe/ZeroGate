# ZeroGate Access — Security Policy

**Version:** 1.0  
**Effective:** 2024-01-01  
**Review cycle:** Annually or after any security incident

---

## 1. Core Principles

1. **Never Trust, Always Verify** — Every request is authenticated and authorized regardless of origin.
2. **Zero Open Ports** — The server never listens for inbound connections. All access flows through the outbound Cloudflare Tunnel.
3. **Least Privilege** — Users and services have the minimum permissions required. No wildcards.
4. **MFA Mandatory** — Password-only authentication is never accepted for any user, including administrators.
5. **Full Audit Trail** — Every authentication event, session, and administrative action is logged and retained for 90 days.

---

## 2. Authentication Requirements

### 2.1 User Authentication

| Requirement | Standard |
|---|---|
| MFA | Mandatory — TOTP or WebAuthn (hardware key) |
| Minimum password length | 14 characters |
| Password complexity | Uppercase + lowercase + digit + symbol |
| Password rotation | Every 90 days (enforced by Authentik policy) |
| Compromised password check | HaveIBeenPwned API (reject if found) |
| Session duration | 8 hours max, re-auth required after expiry |
| Concurrent sessions | Maximum 3 per user |
| Account lockout | 5 failed attempts → 1-hour lockout |

### 2.2 Service Authentication

- All inter-service communication stays on the isolated Docker internal network (`zerogate-internal`).
- Services authenticate via credentials stored in AWS Secrets Manager — never in environment variables or files committed to git.
- Database connections use unique per-service credentials.

---

## 3. Secret Management

### 3.1 Rules

| Rule | Enforcement |
|---|---|
| No secrets in git | `.gitignore` covers all secret files; pre-commit hook recommended |
| No secrets in environment variables on host | Pulled from Secrets Manager at boot via IAM role |
| No secrets in Docker Compose files | All secrets via `.env` (gitignored) or Secrets Manager |
| Secret rotation | Every 90 days (automated where possible) |
| Encryption at rest | AES-256 (AWS Secrets Manager default) |

### 3.2 Secret Inventory

| Secret | Location | Rotation |
|---|---|---|
| Cloudflare Tunnel token | AWS Secrets Manager | Manual (after compromise) |
| Authentik secret key | AWS Secrets Manager | 90 days |
| Database passwords | AWS Secrets Manager | 90 days |
| Grafana admin password | AWS Secrets Manager | 90 days |

### 3.3 Rotation Procedure

```bash
# Rotate all secrets (automated):
./scripts/rotate-secrets.sh --component all

# Rotate tunnel only (manual confirmation required):
./scripts/rotate-secrets.sh --component tunnel

# Always dry-run first:
./scripts/rotate-secrets.sh --dry-run --component all
```

---

## 4. Network Security

### 4.1 Inbound Traffic

- **Zero ports** are open on the EC2 instance's security group.
- **UFW** is active with `deny incoming` as default policy.
- **No SSH port** — shell access is via AWS SSM only.
- The EC2 instance's public IP is never published or used in any DNS record.

### 4.2 Outbound Traffic

- cloudflared maintains a persistent outbound WebSocket to Cloudflare's edge.
- All legitimate traffic flows through this encrypted tunnel.
- Docker containers cannot communicate outside the `zerogate-internal` network except through cloudflared.

### 4.3 Internal Network Isolation

- All containers on `zerogate-internal` (172.20.0.0/16).
- No container has host networking.
- Docker host-level ICC (inter-container communication) is disabled except within the compose network.
- No container mounts the Docker socket unless strictly required (only `authentik-worker` and `promtail` for log collection — these are non-internet-facing).

---

## 5. Container Security

| Control | Implementation |
|---|---|
| Non-root users | All containers run as non-root (enforced by `no-new-privileges`) |
| Read-only filesystem | cloudflared runs read-only; others where possible |
| Privileged mode | Prohibited — no container uses `privileged: true` |
| Image pinning | All images pinned to exact version tag |
| Resource limits | Memory limits on all containers (see docker-compose.yml) |
| Docker socket | Mounted only in authentik-worker and promtail (both non-public) |

---

## 6. AWS Infrastructure Security

| Control | Implementation |
|---|---|
| IMDSv2 only | `http_tokens = required` in Terraform |
| EBS encryption | AES-256, enabled on all volumes |
| EC2 security group | Zero inbound rules — enforced by Terraform |
| IAM least privilege | EC2 role limited to: SSM, read own secrets, write own log group |
| CloudTrail | All API calls logged to S3 (encrypted) |
| GuardDuty | Enabled — alerts on: port scanning, credential misuse, malware |
| VPC Flow Logs | All traffic metadata logged to CloudWatch |
| EBS snapshots | Daily automated via DLM, 7-day retention |

---

## 7. Logging & Monitoring

### 7.1 Retention

| Log type | Retention | Location |
|---|---|---|
| Application logs | 90 days | Loki |
| VPC flow logs | 30 days | CloudWatch |
| CloudTrail | 90 days | S3 |
| EBS snapshots | 7 days | AWS |
| Grafana metrics | 30 days | Prometheus |

### 7.2 Alert Response Times

| Severity | Example | Response SLA |
|---|---|---|
| Critical | Tunnel down, >5 failed logins | 30 minutes |
| High | MFA failures, new country access | 2 hours |
| Warning | Disk >80%, container restart | 8 hours |

---

## 8. Incident Response

### 8.1 Compromised User Account

```
1. Immediately deactivate user in Authentik
   Admin → Directory → Users → [user] → Deactivate
2. Revoke all active sessions
   Admin → Events → Sessions → [user] → Revoke all
3. Rotate MFA: require new device enrollment
4. Review audit logs for access during compromise window
5. Notify affected parties if data was accessed
```

### 8.2 Compromised Tunnel Credentials

```
1. Run: ./scripts/rotate-secrets.sh --component tunnel
2. Verify new tunnel is connected: docker compose logs cloudflared
3. Delete old tunnel from Cloudflare dashboard
4. Review VPC flow logs for unexpected connections
```

### 8.3 Compromised Server

```
1. Isolate: aws ec2 modify-instance-attribute \
     --instance-id <id> --no-source-dest-check  (or stop instance)
2. Snapshot EBS: aws ec2 create-snapshot --volume-id <id> --description "incident-$(date)"
3. Provision new instance via Terraform
4. Restore from last known-good backup
5. Rotate all secrets: ./scripts/rotate-secrets.sh --component all
6. Post-incident: review CloudTrail + VPC flow logs
```

---

## 9. Change Management

- All infrastructure changes go through Terraform (`terraform plan` review required before `apply`).
- Security-affecting changes (auth flow, access policies, network rules) require review by at least one additional person before deployment.
- No direct manual changes to AWS console for anything managed by Terraform.
- All changes to this repository are tracked in git with signed commits recommended.

---

## 10. Compliance Notes

- This platform implements controls consistent with **ISO 27001 A.9** (Access Control) and **NIST SP 800-207** (Zero Trust Architecture).
- Audit logs satisfy **GDPR Article 32** requirements for technical security measures.
- Secret rotation schedule satisfies **PCI-DSS 3.6.1** requirements (if applicable).
