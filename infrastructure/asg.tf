# ============================================================
# Auto Scaling Group — cloudflared tunnel nodes (v2.0 HA)
#
# Each ASG node is a t3.nano that installs only cloudflared
# and connects to the same named tunnel as the primary instance.
# Cloudflare automatically load-balances traffic across all
# healthy connectors and fails over within seconds if one drops.
#
# The main EC2 instance (ec2.tf) continues to run the full
# Docker Compose stack (Authentik, Guacamole, Grafana, etc.).
# ASG nodes are tunnel-ingress only — no application services.
#
# Activate: set enable_cloudflared_asg = true in terraform.tfvars
# ============================================================

# Second public subnet in AZ-b so the ASG spans two AZs.
resource "aws_subnet" "public_b" {
  count                   = var.enable_cloudflared_asg ? 1 : 0
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr_b
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = false

  tags = { Name = "${local.name_prefix}-subnet-public-b" }
}

resource "aws_route_table_association" "public_b" {
  count          = var.enable_cloudflared_asg ? 1 : 0
  subnet_id      = aws_subnet.public_b[0].id
  route_table_id = aws_route_table.public.id
}

data "aws_ami" "ubuntu_24_asg" {
  count       = var.enable_cloudflared_asg ? 1 : 0
  most_recent = true
  owners      = ["099720109477"]

  filter { name = "name";                values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"] }
  filter { name = "virtualization-type"; values = ["hvm"] }
  filter { name = "state";               values = ["available"] }
}

resource "aws_launch_template" "cloudflared" {
  count       = var.enable_cloudflared_asg ? 1 : 0
  name_prefix = "${local.name_prefix}-cloudflared-"
  image_id    = data.aws_ami.ubuntu_24_asg[0].id

  # t3.nano: 2 vCPU, 512 MB RAM — sufficient for cloudflared alone
  instance_type = "t3.nano"

  iam_instance_profile { name = aws_iam_instance_profile.ec2.name }

  # Same zero-inbound security group — ASG nodes need no inbound ports
  vpc_security_group_ids = [aws_security_group.main.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_type           = "gp3"
      volume_size           = 8
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/cloudflared-node.sh.tpl", {
    aws_region  = var.aws_region
    secret_name = "${local.name_prefix}/cloudflare"
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${local.name_prefix}-cloudflared-node"
      Project = "ZeroGate"
      Role    = "cloudflared"
    }
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_autoscaling_group" "cloudflared" {
  count = var.enable_cloudflared_asg ? 1 : 0

  name             = "${local.name_prefix}-cloudflared-asg"
  min_size         = var.cloudflared_asg_min
  max_size         = var.cloudflared_asg_max
  desired_capacity = var.cloudflared_asg_desired

  # Span both public subnets for true multi-AZ HA
  vpc_zone_identifier = concat(
    [aws_subnet.public.id],
    var.enable_cloudflared_asg ? [aws_subnet.public_b[0].id] : []
  )

  launch_template {
    id      = aws_launch_template.cloudflared[0].id
    version = "$Latest"
  }

  health_check_type         = "EC2"
  health_check_grace_period = 120

  # Rolling replacement on launch template updates — keeps min_healthy_percentage online
  instance_refresh {
    strategy = "Rolling"
    preferences { min_healthy_percentage = 50 }
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-cloudflared-node"
    propagate_at_launch = true
  }
  tag {
    key                 = "Project"
    value               = "ZeroGate"
    propagate_at_launch = true
  }
  tag {
    key                 = "Role"
    value               = "cloudflared"
    propagate_at_launch = true
  }
}

# ── CPU-based scaling ─────────────────────────────────────────
# cloudflared is CPU-light under normal traffic; high CPU usually
# means a misconfiguration or DDoS — scale out regardless.

resource "aws_autoscaling_policy" "cloudflared_scale_up" {
  count                  = var.enable_cloudflared_asg ? 1 : 0
  name                   = "${local.name_prefix}-cloudflared-scale-up"
  autoscaling_group_name = aws_autoscaling_group.cloudflared[0].name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 300
}

resource "aws_cloudwatch_metric_alarm" "cloudflared_cpu_high" {
  count               = var.enable_cloudflared_asg ? 1 : 0
  alarm_name          = "${local.name_prefix}-cloudflared-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "cloudflared ASG node CPU > 70% — scale out"

  dimensions = { AutoScalingGroupName = aws_autoscaling_group.cloudflared[0].name }

  alarm_actions = [aws_autoscaling_policy.cloudflared_scale_up[0].arn]

  tags = { Name = "${local.name_prefix}-cloudflared-cpu-high" }
}

resource "aws_autoscaling_policy" "cloudflared_scale_down" {
  count                  = var.enable_cloudflared_asg ? 1 : 0
  name                   = "${local.name_prefix}-cloudflared-scale-down"
  autoscaling_group_name = aws_autoscaling_group.cloudflared[0].name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 300
}

resource "aws_cloudwatch_metric_alarm" "cloudflared_cpu_low" {
  count               = var.enable_cloudflared_asg ? 1 : 0
  alarm_name          = "${local.name_prefix}-cloudflared-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 5
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 10
  alarm_description   = "cloudflared ASG node CPU < 10% — scale in"

  dimensions = { AutoScalingGroupName = aws_autoscaling_group.cloudflared[0].name }

  alarm_actions = [aws_autoscaling_policy.cloudflared_scale_down[0].arn]

  tags = { Name = "${local.name_prefix}-cloudflared-cpu-low" }
}
