# ZeroGate Access — Disaster Recovery Runbook (v2.0)

> **RTO target:** 15 minutes (automated) / 30 minutes (manual)
> **RPO target:** 0 data loss for RDS Multi-AZ; ≤5 min for single-node (EBS snapshot)

---

## Architecture Overview

```
                 Cloudflare Edge
                       │
          ┌────────────┴────────────┐
          │                         │
   cloudflared ASG              cloudflared (main EC2)
   (t3.nano ×2, multi-AZ)       (docker-compose stack)
          │                         │
          └────────────┬────────────┘
                       │  (same named tunnel)
              ┌────────┴────────┐
              │                 │
      Authentik + Guacamole  Grafana / Loki
              │
     ┌────────┴────────┐
     │                 │
  RDS Authentik    RDS Guacamole
  (Primary AZ-a)  (Primary AZ-a)
     │                 │
  Standby AZ-b     Standby AZ-b
  (synchronous)    (synchronous)
```

Failover coverage by component:

| Component | Failure type | Recovery | RTO |
|---|---|---|---|
| cloudflared tunnel | Node terminated | ASG replaces it | 2 min |
| cloudflared tunnel | AZ outage | ASG uses other AZ | 2 min |
| RDS (Authentik / Guacamole) | Primary AZ outage | Multi-AZ automatic failover | 60-120 s |
| Main EC2 | Instance terminated | Manual re-provision | 10-15 min |
| Redis | Container crash | Docker restarts it | 30 s |
| Grafana / Loki | Container crash | Docker restarts it | 30 s |

---

## Section 1 — RDS Failover (Automatic)

Multi-AZ RDS fails over automatically when AWS detects a primary failure.
You do not need to do anything — this section is for verification and DR testing.

### 1.1 Verify failover completed

```bash
# Check current AZ of each RDS instance
aws rds describe-db-instances \
  --db-instance-identifier zerogate-production-authentik \
  --query 'DBInstances[0].{Status:DBInstanceStatus,AZ:AvailabilityZone,MultiAZ:MultiAZ}' \
  --output table

aws rds describe-db-instances \
  --db-instance-identifier zerogate-production-guacamole \
  --query 'DBInstances[0].{Status:DBInstanceStatus,AZ:AvailabilityZone,MultiAZ:MultiAZ}' \
  --output table
```

Expected output after failover: `AvailabilityZone` changes from `eu-west-1a` → `eu-west-1b`.

### 1.2 Verify applications reconnected

```bash
# Check Authentik health
make ssm-tunnel-9000
curl -s http://localhost:9000/-/health/ready/ | jq .

# Check Guacamole is serving the login page
make ssm-tunnel-8080
curl -sI http://localhost:8080/guacamole/
```

### 1.3 Force a test failover (DR drill)

```bash
# Triggers a Multi-AZ failover — causes ~60-120s of DB downtime
make dr-failover COMPONENT=rds-authentik
make dr-failover COMPONENT=rds-guacamole
```

RDS will restart in the standby AZ. Applications will receive connection errors during the
failover window and will reconnect automatically (Authentik retries on startup).

---

## Section 2 — cloudflared ASG Node Failure

Cloudflare Load Balancer distributes traffic across all healthy tunnel connectors.
If one ASG node is terminated, Cloudflare immediately routes all traffic to surviving connectors,
and the ASG launches a replacement node within ~2 minutes.

### 2.1 Monitor ASG health

```bash
make dr-status
# or directly:
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names zerogate-production-cloudflared-asg \
  --query 'AutoScalingGroups[0].{Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,Instances:Instances[*].{ID:InstanceId,State:LifecycleState,Health:HealthStatus,AZ:AvailabilityZone}}' \
  --output json
```

### 2.2 Rolling refresh (update cloudflared version or config)

```bash
# Replaces all nodes one at a time, keeping ≥50% healthy throughout
make dr-asg-refresh
```

### 2.3 Manually scale the ASG

```bash
# Temporarily scale up during an incident
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name zerogate-production-cloudflared-asg \
  --desired-capacity 3

# Return to normal after incident
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name zerogate-production-cloudflared-asg \
  --desired-capacity 2
```

---

## Section 3 — Main EC2 Instance Failure

The main EC2 instance runs the Docker Compose stack (Authentik, Guacamole, Grafana, Redis).
In HA mode, the databases are on RDS (persistent). In single-node mode, data is on EBS.

### 3.1 Single-node mode (no RDS) — restore from EBS snapshot

```bash
# 1. List recent snapshots
aws ec2 describe-snapshots \
  --filters "Name=tag:Project,Values=ZeroGate" \
  --query 'Snapshots[*].{ID:SnapshotId,Time:StartTime,Size:VolumeSize}' \
  --output table | sort -k3

# 2. Note the snapshot ID from the day before the incident

# 3. Re-run Terraform — it provisions a new instance
make apply

# 4. SSH in via SSM and run bootstrap
make ssm
# In the session:
./scripts/bootstrap.sh

# 5. Restore data from snapshot (optional — if you want yesterday's DB state)
# Stop containers, detach EBS, replace with snapshot, re-attach, restart
```

### 3.2 HA mode (RDS enabled) — replace EC2, databases survive

```bash
# 1. Re-provision EC2 (databases are safe on RDS — no data loss)
make apply

# 2. Connect and bootstrap
make ssm
./scripts/bootstrap.sh

# 3. Start HA stack
make ha-up

# Authentik and Guacamole reconnect to existing RDS — all data intact
```

### 3.3 Trigger EC2 replacement via failover script

```bash
# Terminates the current instance (prompts for confirmation)
# Only use this when ASG is active and RDS is enabled
make dr-failover COMPONENT=ec2
```

---

## Section 4 — Terraform State Corruption

If the Terraform state file is corrupted or lost (remote backend only — local state is more fragile):

### 4.1 Restore from S3 versioning

```bash
# List state file versions
aws s3api list-object-versions \
  --bucket "zerogate-tfstate-$(aws sts get-caller-identity --query Account --output text)" \
  --prefix "zerogate/terraform.tfstate" \
  --query 'Versions[*].{ID:VersionId,Modified:LastModified,Size:Size}' \
  --output table

# Restore a previous version
aws s3api restore-object \
  --bucket "zerogate-tfstate-<ACCOUNT_ID>" \
  --key "zerogate/terraform.tfstate" \
  --version-id "<VERSION_ID>"
```

### 4.2 Import existing resources back into state

```bash
# If state is lost and resources still exist, import them:
cd infrastructure

terraform import aws_instance.main <INSTANCE_ID>
terraform import aws_db_instance.authentik[0] zerogate-production-authentik
terraform import aws_db_instance.guacamole[0] zerogate-production-guacamole
terraform import aws_vpc.main <VPC_ID>
terraform import aws_security_group.main <SG_ID>
# ...etc. for each resource shown by: aws ec2 describe-instances --filters "Name=tag:Project,Values=ZeroGate"
```

---

## Section 5 — Full Region Failure (Catastrophic)

If the entire AWS region (eu-west-1) becomes unavailable:

### 5.1 Estimated recovery time: 2-4 hours

This is a black-swan event. RDS Multi-AZ does **not** protect against full-region failure
(both AZs are in the same region). Steps:

1. Choose a recovery region (e.g., eu-west-2)
2. Copy the most recent EBS snapshot to the new region:
   ```bash
   aws ec2 copy-snapshot \
     --source-region eu-west-1 \
     --source-snapshot-id <SNAPSHOT_ID> \
     --destination-region eu-west-2
   ```
3. Update `terraform.tfvars`: `aws_region = "eu-west-2"`
4. Run `make apply` in the new region
5. Restore data from copied snapshot
6. Update Cloudflare Tunnel: create a new tunnel in the new region, update `docker/cloudflared/config.yml`, re-deploy
7. Verify DNS: cloudflared registers new tunnel routes automatically

---

## Section 6 — DR Test Procedure (Quarterly)

Run this quarterly to verify failover works before you need it for real.

```bash
# 1. Check current state
make dr-status

# 2. Force RDS failover (60-120s downtime per DB)
make dr-failover COMPONENT=rds-authentik
sleep 180
make dr-failover COMPONENT=rds-guacamole
sleep 180

# 3. Verify applications recovered
make health

# 4. Force ASG node replacement
make dr-asg-refresh

# 5. Verify tunnel connectors
make ssm
docker exec zerogate-cloudflared-1 cloudflared tunnel info

# 6. Log the test
echo "$(date -u) DR test passed — RTO measured: <N> minutes" >> docs/dr-test-log.txt
```

---

## Emergency Contacts

| Role | Contact |
|---|---|
| Primary admin | Configured in `admin_email` (terraform.tfvars) |
| AWS Support | https://console.aws.amazon.com/support |
| Cloudflare Status | https://www.cloudflarestatus.com |
| Authentik Status | Check: `make ssm-tunnel-9000` → `http://localhost:9000/-/health/ready/` |

---

## Runbook Quick Reference

```bash
make dr-status                         # Show HA component health
make dr-failover COMPONENT=rds-authentik  # Force RDS AZ failover
make dr-failover COMPONENT=rds-guacamole
make dr-failover COMPONENT=asg-refresh  # Rolling ASG node refresh
make dr-failover COMPONENT=ec2          # Terminate + replace main EC2
make backend-init                       # Create/migrate Terraform remote state
make ha-apply                          # Provision RDS + ASG
make ha-up                             # Start stack in HA mode
make ha-guac-init                      # Init Guacamole schema on RDS
```
