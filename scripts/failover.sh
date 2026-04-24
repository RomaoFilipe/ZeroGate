#!/usr/bin/env bash
# ZeroGate Access — Automated Failover Script (v2.0)
#
# Triggers or monitors a failover for the selected component.
# Requires HA mode to be active (enable_rds / enable_cloudflared_asg = true).
#
# Usage:
#   ./scripts/failover.sh --component rds-authentik   # reboot RDS to force AZ failover
#   ./scripts/failover.sh --component rds-guacamole
#   ./scripts/failover.sh --component ec2             # replace main EC2 instance
#   ./scripts/failover.sh --component asg-refresh     # rolling refresh of cloudflared ASG
#   ./scripts/failover.sh --status                    # show HA component health
#   make dr-failover COMPONENT=rds-authentik
set -euo pipefail

COMPONENT=""
STATUS_ONLY=false
DRY_RUN=false
AWS_REGION="${AWS_REGION:-eu-west-1}"
INFRA_DIR="$(cd "$(dirname "$0")/../infrastructure" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --component) COMPONENT="$2"; shift 2 ;;
    --status)    STATUS_ONLY=true; shift ;;
    --dry-run)   DRY_RUN=true;    shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

log()  { echo "[$(date -u +%H:%M:%SZ)] $*"; }
info() { log "INFO  $*"; }
ok()   { log "OK    $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*" >&2; }

# ── Resolve Terraform outputs ────────────────────────────────
tf_output() {
  (cd "$INFRA_DIR" && terraform output -raw "$1" 2>/dev/null) || echo ""
}

NAME_PREFIX=$(tf_output instance_id 2>/dev/null | sed 's/-server.*//' || echo "zerogate-production")
RDS_AUTH_ID="${NAME_PREFIX}-authentik"
RDS_GUAC_ID="${NAME_PREFIX}-guacamole"
ASG_NAME=$(tf_output cloudflared_asg_name 2>/dev/null || echo "")
EC2_ID=$(tf_output instance_id 2>/dev/null || echo "")

# ── Status report ─────────────────────────────────────────────
show_status() {
  echo ""
  echo "════════════════════════════════════════════"
  echo " ZeroGate Access HA Status"
  echo "════════════════════════════════════════════"

  # EC2
  if [[ -n "$EC2_ID" ]]; then
    EC2_STATE=$(aws ec2 describe-instances \
      --instance-ids "$EC2_ID" \
      --region "$AWS_REGION" \
      --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "unknown")
    echo " EC2 (main):        $EC2_ID — $EC2_STATE"
  else
    echo " EC2 (main):        not found in Terraform state"
  fi

  # RDS Authentik
  RDS_AUTH_STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier "$RDS_AUTH_ID" \
    --region "$AWS_REGION" \
    --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,AZ:AvailabilityZone}' \
    --output text 2>/dev/null || echo "not provisioned")
  echo " RDS Authentik:     $RDS_AUTH_ID — $RDS_AUTH_STATUS"

  # RDS Guacamole
  RDS_GUAC_STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier "$RDS_GUAC_ID" \
    --region "$AWS_REGION" \
    --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,AZ:AvailabilityZone}' \
    --output text 2>/dev/null || echo "not provisioned")
  echo " RDS Guacamole:     $RDS_GUAC_ID — $RDS_GUAC_STATUS"

  # ASG
  if [[ -n "$ASG_NAME" && "$ASG_NAME" != "ASG disabled" ]]; then
    ASG_STATUS=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --region "$AWS_REGION" \
      --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize,Healthy:Instances[?HealthStatus==`Healthy`]|length(@)}' \
      --output text 2>/dev/null || echo "not provisioned")
    echo " cloudflared ASG:   $ASG_NAME — $ASG_STATUS"
  else
    echo " cloudflared ASG:   disabled (enable_cloudflared_asg = false)"
  fi

  echo "════════════════════════════════════════════"
  echo ""
}

[[ "$STATUS_ONLY" == "true" ]] && { show_status; exit 0; }

[[ -z "$COMPONENT" ]] && { err "Specify --component or --status"; exit 1; }

# ── Failover actions ──────────────────────────────────────────
case "$COMPONENT" in

  rds-authentik)
    info "Initiating Multi-AZ failover for RDS Authentik ($RDS_AUTH_ID)"
    info "AWS will promote the standby in the second AZ — expect 60-120s downtime"
    [[ "$DRY_RUN" == "true" ]] && { warn "DRY RUN — no action taken"; exit 0; }
    aws rds reboot-db-instance \
      --db-instance-identifier "$RDS_AUTH_ID" \
      --force-failover \
      --region "$AWS_REGION"
    ok "Failover initiated. Monitor with: make dr-status"
    ;;

  rds-guacamole)
    info "Initiating Multi-AZ failover for RDS Guacamole ($RDS_GUAC_ID)"
    [[ "$DRY_RUN" == "true" ]] && { warn "DRY RUN — no action taken"; exit 0; }
    aws rds reboot-db-instance \
      --db-instance-identifier "$RDS_GUAC_ID" \
      --force-failover \
      --region "$AWS_REGION"
    ok "Failover initiated. Monitor with: make dr-status"
    ;;

  asg-refresh)
    [[ -z "$ASG_NAME" || "$ASG_NAME" == "ASG disabled" ]] && {
      err "cloudflared ASG is not enabled. Set enable_cloudflared_asg = true and run make ha-apply"
      exit 1
    }
    info "Starting rolling refresh of cloudflared ASG ($ASG_NAME)"
    info "New instances will start before old ones are terminated (min_healthy=50%)"
    [[ "$DRY_RUN" == "true" ]] && { warn "DRY RUN — no action taken"; exit 0; }
    aws autoscaling start-instance-refresh \
      --auto-scaling-group-name "$ASG_NAME" \
      --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":120}' \
      --region "$AWS_REGION"
    ok "Instance refresh started. Monitor with: make dr-status"
    ;;

  ec2)
    [[ -z "$EC2_ID" ]] && { err "Cannot determine EC2 instance ID from Terraform state"; exit 1; }
    warn "Terminating EC2 instance $EC2_ID"
    warn "Ensure cloudflared ASG is active (make dr-status) before terminating the main instance"
    read -p "Type 'failover' to confirm: " confirm
    [[ "$confirm" != "failover" ]] && { info "Cancelled"; exit 0; }
    [[ "$DRY_RUN" == "true" ]] && { warn "DRY RUN — no action taken"; exit 0; }
    aws ec2 terminate-instances --instance-ids "$EC2_ID" --region "$AWS_REGION"
    warn "Instance terminated. Re-provision with: make apply && make up"
    ;;

  *)
    err "Unknown component: $COMPONENT"
    echo "Valid components: rds-authentik, rds-guacamole, asg-refresh, ec2"
    exit 1
    ;;
esac
