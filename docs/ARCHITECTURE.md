# ZeroGate — Architecture

## Design Decisions

### Why Cloudflare Tunnel over a reverse proxy?

A traditional reverse proxy (Nginx, Traefik) must listen on a public port. That port is scannable, fingerprintable, and exploitable before authentication can occur. Cloudflare Tunnel inverts this: the server calls out to Cloudflare, never the other way. There is no port to scan, no IP to target.

The tradeoff: you depend on Cloudflare for the data plane. For organisations already on Cloudflare DNS (which is nearly universal), this is an acceptable dependency with a well-defined blast radius — if Cloudflare is unavailable, access is unavailable, but the internal network is untouched.

### Why Authentik over Keycloak / other IdPs?

Authentik ships as a single Docker Compose stack, has sensible defaults, supports OIDC/SAML/LDAP, has a polished UI, and is MIT-licensed. Keycloak is more feature-rich but significantly heavier and harder to operate for small teams. Auth0/Okta are SaaS dependencies. For a self-hosted, single-operator platform, Authentik hits the right balance.

### Why Guacamole for remote access?

Zero client footprint. Users access SSH/RDP/VNC via a standard browser — no VPN client, no SSH client, no RDP client on their machine. The protocol is proxied server-side by guacd. This also means clipboard, file transfer, and local device access can be controlled at a single point.

### Why PostgreSQL for both Authentik and Guacamole?

They each run their own PostgreSQL instance (separate containers). Sharing a database between applications violates least-privilege principles and complicates backup/restore. Two lightweight PostgreSQL containers on a t2.micro is fine — each uses ~50–100 MB RAM in steady state.

---

## Network Topology

```
INTERNET
  │
  │  HTTPS (TLS 1.3) — user browser → Cloudflare edge
  ▼
CLOUDFLARE EDGE
  │  Cloudflare Access: validates identity, checks policy
  │  Cloudflare Tunnel: forwards authenticated request
  │
  │  Encrypted WebSocket (outbound-only, initiated by cloudflared)
  ▼
EC2 INSTANCE (Ubuntu 24.04)
  Public IP (EIP) — Security Group: 0 inbound rules
  UFW: deny all incoming

  Docker bridge network: zerogate-internal (172.20.0.0/16)
  ┌─────────────────────────────────────────────────────────┐
  │  cloudflared ──► authentik-server:9000                  │
  │              ──► guacamole:8080                         │
  │              ──► grafana:3000                           │
  │                                                         │
  │  authentik-server ──► authentik-db:5432                 │
  │                   ──► authentik-redis:6379              │
  │                                                         │
  │  guacamole ──► guacd:4822                               │
  │            ──► guacamole-db:5432                        │
  │                                                         │
  │  promtail ──► loki:3100                                 │
  │  grafana  ──► loki:3100  ──► prometheus:9090            │
  │                                                         │
  │  prometheus ──► node-exporter:9100                      │
  │             ──► cadvisor:8080                           │
  └─────────────────────────────────────────────────────────┘
```

---

## Service Dependency Graph

```
cloudflared
  └─ depends on: authentik-server (healthy)
  └─ depends on: guacamole (healthy)
  └─ depends on: grafana (healthy)

authentik-server / authentik-worker
  └─ depends on: authentik-db (healthy)
  └─ depends on: authentik-redis (healthy)

guacamole
  └─ depends on: guacd (healthy)
  └─ depends on: guacamole-db (healthy)

grafana
  └─ depends on: loki (healthy)
  └─ depends on: prometheus (healthy)

promtail
  └─ depends on: loki (healthy)
```

---

## Authentication Request Flow

```
1.  Browser → https://access.yourdomain.com
2.  Cloudflare edge intercepts — no active CF Access session
3.  Browser redirected to: https://auth.yourdomain.com/application/o/authorize/
4.  Authentik presents login page (Stage 1: Identification)
5.  User enters username → Authentik validates (Stage 2: Password)
6.  Password correct → Authentik prompts TOTP (Stage 3: MFA)
7.  TOTP verified → Authentik issues OIDC ID token
8.  Token returned to Cloudflare Access via redirect
9.  CF Access validates token signature (JWKS endpoint on Authentik)
10. CF Access checks policy: user in `remote-access` group? → Yes
11. CF Access issues its own session cookie (8h)
12. Request forwarded through Cloudflare Tunnel to cloudflared on EC2
13. cloudflared routes to guacamole:8080
14. Guacamole validates CF Access JWT header (no second login needed)
15. User sees Guacamole connection list in browser
16. User connects to a resource → guacd proxies the protocol
17. All events logged: Authentik → stdout → Promtail → Loki → Grafana
```

---

## Secrets Flow

```
Terraform (local) ──► AWS Secrets Manager (encrypted at rest)
                                │
                                │ (IAM role — EC2 only, read-only)
                                ▼
                       bootstrap.sh (runs once on EC2)
                                │
                                ▼
                       /opt/zerogate/docker/.env (mode 600)
                                │
                                ▼
                       docker compose (env_file)
                                │
                                ▼
                       containers (environment variables)
```

No secret ever touches disk unencrypted except the `.env` file on the EC2 instance, which is readable only by root (mode 600) and excluded from git.

---

## Data at Rest

| Data | Location | Encryption |
|---|---|---|
| Authentik DB (users, flows, sessions) | Docker volume → EBS | EBS AES-256 |
| Authentik media | Docker volume → EBS | EBS AES-256 |
| Guacamole DB (connections, users) | Docker volume → EBS | EBS AES-256 |
| Loki logs | Docker volume → EBS | EBS AES-256 |
| Prometheus metrics | Docker volume → EBS | EBS AES-256 |
| Grafana dashboards | Docker volume → EBS | EBS AES-256 |
| Backups | S3 | S3 SSE-AES256 |
| CloudTrail logs | S3 | S3 SSE-AES256 |
| Secrets | AWS Secrets Manager | AES-256 (managed) |

---

## Capacity Planning (t2.micro: 1 vCPU, 1 GB RAM)

| Service | Memory (steady) | Memory (peak) |
|---|---|---|
| authentik-server | ~200 MB | ~500 MB |
| authentik-worker | ~150 MB | ~300 MB |
| authentik-db | ~50 MB | ~150 MB |
| authentik-redis | ~20 MB | ~50 MB |
| guacamole | ~100 MB | ~300 MB |
| guacd | ~30 MB | ~200 MB (per session) |
| guacamole-db | ~30 MB | ~80 MB |
| grafana | ~100 MB | ~200 MB |
| loki | ~80 MB | ~200 MB |
| prometheus | ~80 MB | ~150 MB |
| promtail | ~30 MB | ~60 MB |
| node-exporter | ~10 MB | ~20 MB |
| cadvisor | ~30 MB | ~60 MB |
| cloudflared | ~20 MB | ~40 MB |
| **Total** | **~930 MB** | **~2.3 GB** |

**Recommendation:** t2.micro (1 GB) is tight with all services running. Use swap (2 GB recommended) or upgrade to t3.small (2 GB) for production with concurrent Guacamole sessions. Each Guacamole RDP session uses ~50–150 MB additional RAM in guacd.

```bash
# Add 2 GB swap on EC2:
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

---

## Upgrade Strategy

```bash
# Update a specific service image:
# 1. Edit docker-compose.yml to pin new version
# 2. Pull and recreate (zero-downtime for non-critical services):
docker compose pull authentik-server authentik-worker
docker compose up -d --no-deps authentik-server authentik-worker

# For database upgrades: always backup first:
./scripts/backup.sh --component databases
docker compose pull authentik-db
docker compose up -d --no-deps authentik-db

# Verify after upgrade:
./scripts/health-check.sh
```
