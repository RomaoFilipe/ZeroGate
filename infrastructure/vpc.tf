resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-igw" }
}

# Single public subnet — EC2 lives here with outbound internet for cloudflared.
# The security group (in ec2.tf) enforces ZERO inbound rules at the packet level.
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = false # We assign an EIP explicitly — no auto-public-IP

  tags = { Name = "${local.name_prefix}-subnet-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name_prefix}-rtb-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Elastic IP — stable outbound address for cloudflared tunnel
resource "aws_eip" "main" {
  domain   = "vpc"
  instance = aws_instance.main.id

  depends_on = [aws_internet_gateway.main]

  tags = { Name = "${local.name_prefix}-eip" }
}

# VPC Flow Logs — ship all network traffic metadata to CloudWatch
resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn

  tags = { Name = "${local.name_prefix}-flow-logs" }
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/flowlogs/${local.name_prefix}"
  retention_in_days = 30

  tags = { Name = "${local.name_prefix}-flow-logs-cw" }
}
