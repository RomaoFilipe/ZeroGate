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
