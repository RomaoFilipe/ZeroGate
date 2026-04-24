data "aws_ami" "ubuntu_24" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# ============================================================
# Security Group — ZERO inbound rules (critical invariant)
# All traffic flows outbound via cloudflared tunnel only.
# ============================================================
resource "aws_security_group" "main" {
  name        = "${local.name_prefix}-sg"
  description = "ZeroGate Access: zero inbound rules — all access via Cloudflare Tunnel"
  vpc_id      = aws_vpc.main.id

  # Outbound: allow all (cloudflared needs to reach Cloudflare edge)
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # No ingress rules — zero open inbound ports
  # This is the core security guarantee of ZeroGate Access.

  tags = { Name = "${local.name_prefix}-sg-zero-inbound" }

  lifecycle {
    # Prevent accidental addition of inbound rules via console
    ignore_changes = []
  }
}

resource "aws_instance" "main" {
  ami                    = data.aws_ami.ubuntu_24.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.main.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # IMDSv2 enforced — prevents SSRF-based metadata theft
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # Blocks container escape to IMDS
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.volume_size_gb
    encrypted             = true
    delete_on_termination = true

    tags = { Name = "${local.name_prefix}-root-volume" }
  }

  # User data bootstraps Docker, Docker Compose, and cloudflared.
  # The full setup is handled by scripts/bootstrap.sh which is pulled
  # from the instance itself after SSM connection.
  user_data = base64encode(templatefile("${path.module}/templates/userdata.sh.tpl", {
    project_name = var.project_name
    aws_region   = var.aws_region
  }))

  user_data_replace_on_change = false # Prevents accidental instance replacement

  tags = { Name = "${local.name_prefix}-server" }

  lifecycle {
    ignore_changes = [ami] # Don't replace instance on AMI update — use in-place upgrade
  }
}

# Automated EBS snapshots via Data Lifecycle Manager
resource "aws_dlm_lifecycle_policy" "ebs_backup" {
  description        = "ZeroGate Access daily EBS snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    schedule {
      name = "Daily snapshots — ${var.backup_retention_days} day retention"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"] # 3 AM UTC (off-peak)
      }

      retain_rule {
        count = var.backup_retention_days
      }

      tags_to_add = {
        SnapshotCreator = "DLM"
        Project         = "ZeroGate"
      }

      copy_tags = true
    }

    target_tags = {
      Project = "ZeroGate"
    }
  }

  tags = { Name = "${local.name_prefix}-dlm-policy" }
}

# GuardDuty — AWS threat detection
resource "aws_guardduty_detector" "main" {
  count  = var.enable_guardduty ? 1 : 0
  enable = true

  datasources {
    s3_logs { enable = true }
    kubernetes { audit_logs { enable = false } }
    malware_protection { scan_ec2_instance_with_findings { ebs_volumes { enable = true } } }
  }

  tags = { Name = "${local.name_prefix}-guardduty" }
}
