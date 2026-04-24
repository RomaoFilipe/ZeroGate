# ============================================================
# RDS Multi-AZ — Authentik + Guacamole databases (v2.0 HA)
#
# Replaces the Docker Compose postgres containers in HA mode.
# AWS manages a synchronous standby replica in a second AZ;
# failover is automatic (60-120s) with zero data loss.
#
# Activate: set enable_rds = true in terraform.tfvars
# Then run:
#   make ha-apply
#   make ha-guac-init    # initialise Guacamole schema on RDS
#   make ha-up           # start stack with HA override
# ============================================================

# ── Private subnets for RDS (no internet access) ─────────────
# Two subnets in different AZs — required by aws_db_subnet_group.
resource "aws_subnet" "private_a" {
  count             = var.enable_rds ? 1 : 0
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr_a
  availability_zone = "${var.aws_region}a"

  tags = { Name = "${local.name_prefix}-subnet-private-a" }
}

resource "aws_subnet" "private_b" {
  count             = var.enable_rds ? 1 : 0
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr_b
  availability_zone = "${var.aws_region}b"

  tags = { Name = "${local.name_prefix}-subnet-private-b" }
}

resource "aws_db_subnet_group" "main" {
  count      = var.enable_rds ? 1 : 0
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = [aws_subnet.private_a[0].id, aws_subnet.private_b[0].id]

  tags = { Name = "${local.name_prefix}-db-subnet-group" }
}

# Allow PostgreSQL (5432) only from the main EC2 instance and cloudflared ASG nodes.
resource "aws_security_group" "rds" {
  count       = var.enable_rds ? 1 : 0
  name        = "${local.name_prefix}-rds-sg"
  description = "Allow PostgreSQL from ZeroGate Access instances only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from main EC2"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.main.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-rds-sg" }
}

# ── Authentik RDS ─────────────────────────────────────────────
resource "aws_db_instance" "authentik" {
  count = var.enable_rds ? 1 : 0

  identifier     = "${local.name_prefix}-authentik"
  engine         = "postgres"
  engine_version = "16.3"
  instance_class = var.rds_instance_class

  db_name  = "authentik"
  username = "authentik"
  password = random_password.authentik_db_password.result

  # Synchronous standby in second AZ — automatic failover, zero data loss.
  multi_az = var.rds_multi_az

  allocated_storage     = var.rds_storage_gb
  max_allocated_storage = var.rds_storage_gb * 3
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]

  backup_retention_period    = var.backup_retention_days
  backup_window              = "03:00-04:00"
  maintenance_window         = "Mon:04:00-Mon:05:00"
  auto_minor_version_upgrade = true
  deletion_protection        = var.environment == "production"

  skip_final_snapshot       = var.environment != "production"
  final_snapshot_identifier = "${local.name_prefix}-authentik-final"

  performance_insights_enabled = true

  tags = { Name = "${local.name_prefix}-rds-authentik" }
}

# ── Guacamole RDS ─────────────────────────────────────────────
resource "aws_db_instance" "guacamole" {
  count = var.enable_rds ? 1 : 0

  identifier     = "${local.name_prefix}-guacamole"
  engine         = "postgres"
  engine_version = "16.3"
  instance_class = var.rds_instance_class

  db_name  = "guacamole_db"
  username = "guacamole_user"
  password = random_password.guacamole_db_password.result

  multi_az = var.rds_multi_az

  allocated_storage     = var.rds_storage_gb
  max_allocated_storage = var.rds_storage_gb * 3
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]

  backup_retention_period    = var.backup_retention_days
  backup_window              = "03:00-04:00"
  maintenance_window         = "Mon:04:00-Mon:05:00"
  auto_minor_version_upgrade = true
  deletion_protection        = var.environment == "production"

  skip_final_snapshot       = var.environment != "production"
  final_snapshot_identifier = "${local.name_prefix}-guacamole-final"

  performance_insights_enabled = true

  tags = { Name = "${local.name_prefix}-rds-guacamole" }
}

# ── Store RDS endpoints in Secrets Manager ────────────────────
# bootstrap.sh reads this secret to populate .env on the EC2 instance.
resource "aws_secretsmanager_secret" "rds" {
  count                   = var.enable_rds ? 1 : 0
  name                    = "${local.name_prefix}/rds"
  description             = "ZeroGate Access RDS endpoints and credentials"
  recovery_window_in_days = 7

  tags = { Name = "${local.name_prefix}-secret-rds" }
}

resource "aws_secretsmanager_secret_version" "rds" {
  count     = var.enable_rds ? 1 : 0
  secret_id = aws_secretsmanager_secret.rds[0].id

  secret_string = jsonencode({
    AUTHENTIK_DB_HOST     = aws_db_instance.authentik[0].address
    AUTHENTIK_DB_PORT     = tostring(aws_db_instance.authentik[0].port)
    AUTHENTIK_DB_NAME     = aws_db_instance.authentik[0].db_name
    AUTHENTIK_DB_USER     = aws_db_instance.authentik[0].username
    AUTHENTIK_DB_PASSWORD = random_password.authentik_db_password.result
    GUACAMOLE_DB_HOST     = aws_db_instance.guacamole[0].address
    GUACAMOLE_DB_PORT     = tostring(aws_db_instance.guacamole[0].port)
    GUACAMOLE_DB_NAME     = aws_db_instance.guacamole[0].db_name
    GUACAMOLE_DB_USER     = aws_db_instance.guacamole[0].username
    GUACAMOLE_DB_PASSWORD = random_password.guacamole_db_password.result
  })
}

resource "aws_iam_role_policy" "rds_secret_read" {
  count = var.enable_rds ? 1 : 0
  name  = "${local.name_prefix}-rds-secret-read"
  role  = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = aws_secretsmanager_secret.rds[0].arn
    }]
  })
}
