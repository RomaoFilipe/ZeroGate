output "instance_id" {
  description = "EC2 instance ID (use with SSM for shell access)"
  value       = aws_instance.main.id
}

output "instance_private_ip" {
  description = "Private IP of the EC2 instance"
  value       = aws_instance.main.private_ip
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "subnet_id" {
  description = "Public subnet ID"
  value       = aws_subnet.public.id
}

output "security_group_id" {
  description = "Security group ID — verify with: aws ec2 describe-security-groups --group-ids <id> --query 'SecurityGroups[0].IpPermissions'"
  value       = aws_security_group.main.id
}

output "iam_role_arn" {
  description = "IAM role ARN attached to the EC2 instance"
  value       = aws_iam_role.ec2.arn
}

output "instance_profile_name" {
  description = "IAM instance profile name"
  value       = aws_iam_instance_profile.ec2.name
}

output "ssm_connect_command" {
  description = "Command to open a shell session via AWS SSM (no SSH/open ports needed)"
  value       = "aws ssm start-session --target ${aws_instance.main.id} --region ${var.aws_region}"
}

output "ssm_tunnel_command" {
  description = "Command to forward a port via SSM (replace LOCAL_PORT and REMOTE_PORT)"
  value       = "aws ssm start-session --target ${aws_instance.main.id} --region ${var.aws_region} --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"REMOTE_PORT\"],\"localPortNumber\":[\"LOCAL_PORT\"]}'"
}

output "secrets_arns" {
  description = "ARNs of the secrets stored in AWS Secrets Manager"
  value = {
    authentik  = aws_secretsmanager_secret.authentik.arn
    guacamole  = aws_secretsmanager_secret.guacamole.arn
    grafana    = aws_secretsmanager_secret.grafana.arn
    cloudflare = aws_secretsmanager_secret.cloudflare.arn
  }
}

output "cloudtrail_bucket" {
  description = "S3 bucket storing CloudTrail logs"
  value       = var.enable_cloudtrail ? aws_s3_bucket.cloudtrail[0].bucket : "CloudTrail disabled"
}

# ── v2.0 HA outputs ──────────────────────────────────────────

output "rds_authentik_endpoint" {
  description = "RDS endpoint for Authentik database (empty if enable_rds = false)"
  value       = var.enable_rds ? aws_db_instance.authentik[0].address : "RDS disabled — using local Docker postgres"
}

output "rds_guacamole_endpoint" {
  description = "RDS endpoint for Guacamole database (empty if enable_rds = false)"
  value       = var.enable_rds ? aws_db_instance.guacamole[0].address : "RDS disabled — using local Docker postgres"
}

output "rds_secret_arn" {
  description = "Secrets Manager ARN containing RDS endpoints and credentials"
  value       = var.enable_rds ? aws_secretsmanager_secret.rds[0].arn : "RDS disabled"
}

output "cloudflared_asg_name" {
  description = "Auto Scaling Group name for cloudflared nodes (empty if disabled)"
  value       = var.enable_cloudflared_asg ? aws_autoscaling_group.cloudflared[0].name : "ASG disabled"
}

output "backend_init_command" {
  description = "Command to create the S3 + DynamoDB backend resources and migrate state"
  value       = "make backend-init AWS_REGION=${var.aws_region}"
}
