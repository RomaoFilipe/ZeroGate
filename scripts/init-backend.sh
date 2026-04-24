#!/usr/bin/env bash
# ZeroGate Access — Initialise Terraform S3 remote state backend (v2.0)
#
# Creates the S3 bucket (versioned, encrypted) and DynamoDB lock table,
# then migrates the existing local state to the remote backend.
#
# Run once, before any other Terraform operations in a new environment.
# Usage:
#   ./scripts/init-backend.sh [--region eu-west-1] [--account-id 123456789012]
#   make backend-init
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────
REGION="${AWS_REGION:-eu-west-1}"
DRY_RUN=false
ACCOUNT_ID=""

# ── Arg parsing ───────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)     REGION="$2";     shift 2 ;;
    --account-id) ACCOUNT_ID="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true;    shift   ;;
    *) echo "Unknown argument: $1"; exit 1  ;;
  esac
done

# ── Resolve account ID if not provided ───────────────────────
if [[ -z "$ACCOUNT_ID" ]]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
fi

BUCKET="zerogate-tfstate-${ACCOUNT_ID}"
DYNAMO_TABLE="zerogate-tfstate-lock"
INFRA_DIR="$(cd "$(dirname "$0")/../infrastructure" && pwd)"

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
info() { log "INFO  $*"; }
ok()   { log "OK    $*"; }
warn() { log "WARN  $*"; }

info "Region:       $REGION"
info "Account ID:   $ACCOUNT_ID"
info "S3 bucket:    $BUCKET"
info "DynamoDB:     $DYNAMO_TABLE"
info "Infra dir:    $INFRA_DIR"
[[ "$DRY_RUN" == "true" ]] && warn "DRY RUN — no changes will be made"
echo ""

# ── Step 1: Create S3 bucket ──────────────────────────────────
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  ok "S3 bucket already exists: $BUCKET"
else
  info "Creating S3 bucket: $BUCKET"
  if [[ "$DRY_RUN" == "false" ]]; then
    if [[ "$REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
    else
      aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION"
    fi
    ok "S3 bucket created"
  fi
fi

# ── Step 2: Enable versioning ─────────────────────────────────
info "Enabling versioning on $BUCKET"
if [[ "$DRY_RUN" == "false" ]]; then
  aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled
  ok "Versioning enabled"
fi

# ── Step 3: Enable encryption ─────────────────────────────────
info "Enabling AES-256 encryption on $BUCKET"
if [[ "$DRY_RUN" == "false" ]]; then
  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
  ok "Encryption enabled"
fi

# ── Step 4: Block public access ───────────────────────────────
info "Blocking public access on $BUCKET"
if [[ "$DRY_RUN" == "false" ]]; then
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  ok "Public access blocked"
fi

# ── Step 5: Create DynamoDB lock table ───────────────────────
if aws dynamodb describe-table --table-name "$DYNAMO_TABLE" --region "$REGION" &>/dev/null; then
  ok "DynamoDB table already exists: $DYNAMO_TABLE"
else
  info "Creating DynamoDB table: $DYNAMO_TABLE"
  if [[ "$DRY_RUN" == "false" ]]; then
    aws dynamodb create-table \
      --table-name "$DYNAMO_TABLE" \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region "$REGION"
    ok "DynamoDB table created"
  fi
fi

# ── Step 6: Update main.tf backend block ─────────────────────
MAIN_TF="${INFRA_DIR}/main.tf"
info "Checking backend configuration in $MAIN_TF"

if grep -q 'backend "s3"' "$MAIN_TF" && ! grep -q '# backend "s3"' "$MAIN_TF"; then
  ok "Backend already configured in main.tf"
else
  info "Writing backend config to main.tf"
  if [[ "$DRY_RUN" == "false" ]]; then
    # Replace the commented-out backend block with an active one
    python3 - <<PYEOF
import re

with open('${MAIN_TF}', 'r') as f:
    content = f.read()

new_backend = '''  backend "s3" {
    bucket         = "${BUCKET}"
    key            = "zerogate/terraform.tfstate"
    region         = "${REGION}"
    dynamodb_table = "${DYNAMO_TABLE}"
    encrypt        = true
  }'''

# Remove the comment block + commented backend block
content = re.sub(
    r'\s*# Uncomment after.*?# \}\n',
    '\n',
    content,
    flags=re.DOTALL
)
# Remove the remaining commented backend lines
content = re.sub(
    r'\s*#\s*backend "s3" \{[^}]*\}',
    '',
    content,
    flags=re.DOTALL
)
# Insert active backend block inside terraform {}
content = content.replace(
    'terraform {',
    'terraform {\n' + new_backend,
    1
)

with open('${MAIN_TF}', 'w') as f:
    f.write(content)
PYEOF
    ok "main.tf backend block activated"
  fi
fi

# ── Step 7: Migrate state ─────────────────────────────────────
echo ""
info "Running: terraform init -migrate-state"
if [[ "$DRY_RUN" == "false" ]]; then
  (cd "$INFRA_DIR" && terraform init -migrate-state -input=false)
  ok "State migrated to S3"
fi

echo ""
echo "======================================================"
echo " Terraform remote state is now stored in:"
echo "   s3://${BUCKET}/zerogate/terraform.tfstate"
echo " Lock table: ${DYNAMO_TABLE} (${REGION})"
echo ""
echo " Verify: terraform state list"
echo "======================================================"
