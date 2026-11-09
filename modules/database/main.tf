# ------------------------------------------------------------------------------------------
# RDS MySQL 8.4 (LTS) in the private subnets.
# 8.0 left RDS standard support on 2026-07-31 — running it now incurs Extended Support fees.
# ------------------------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name        = "${local.name_prefix}-db"
  description = "Private subnets for RDS (must span >= 2 AZs)"
  subnet_ids  = var.subnet_ids

  tags = { Name = "${local.name_prefix}-db-subnets" }
}

resource "aws_db_parameter_group" "mysql" {
  name_prefix = "${local.name_prefix}-mysql84-"
  family      = "mysql8.4"
  description = "Custom MySQL 8.4 settings for ${local.name_prefix}"

  # Reject any connection that isn't TLS-encrypted.
  parameter {
    name  = "require_secure_transport"
    value = "1"
  }

  # Log queries slower than 1s (exported to CloudWatch Logs, see logs.tf in this module).
  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "mysql" {
  identifier     = local.db_identifier
  engine         = "mysql"
  engine_version = "8.4" # major only -> RDS picks the default minor; auto_minor_version_upgrade keeps it patched

  instance_class        = var.instance_class
  allocated_storage     = 20
  max_allocated_storage = 0 # storage autoscaling off (lab)
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "retail"
  username = "dbadmin"
  # RDS generates the master password and stores/rotates it in Secrets Manager.
  # The password never appears in Terraform code or state.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.security_group_id]
  parameter_group_name   = aws_db_parameter_group.mysql.name
  publicly_accessible    = false
  multi_az               = var.multi_az # synchronous standby in another AZ: ~2x price

  backup_retention_period    = var.backup_retention_days
  backup_window              = "17:00-17:30" # UTC = 00:00-00:30 Bangkok
  maintenance_window         = "sun:18:00-sun:18:30"
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true

  # dev: false / true (cheap to throw away). prod: true / false (see envs/prod).
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.db_identifier}-final"
  apply_immediately         = var.apply_immediately

  # Ship MySQL error + slow query logs to CloudWatch Logs (Phase 7). The log groups are created
  # first (logs.tf) so they get a retention period instead of "Never expire".
  enabled_cloudwatch_logs_exports = local.rds_log_exports
  depends_on                      = [aws_cloudwatch_log_group.rds]

  tags = { Name = "${local.name_prefix}-mysql" }
}

# ------------------------------------------------------------------------------------------
# Application DB user credentials (least privilege; the app never uses the master user).
#
# `ephemeral` random_password + `secret_string_wo` (write-only): the generated password is sent
# to Secrets Manager but is NEVER stored in Terraform state or plan files.
# Rotate: bump var.app_password_version -> apply -> instance runs db-bootstrap (ALTER USER).
# ------------------------------------------------------------------------------------------
ephemeral "random_password" "db_app" {
  length  = 32
  special = false # avoids quoting issues in .env files / shells; 32 alnum chars ≈ 190 bits
}

resource "aws_secretsmanager_secret" "db_app" {
  name                    = "${local.param_prefix}/db/app"
  description             = "MySQL credentials for the retail-health application user"
  recovery_window_in_days = 0 # lab: delete immediately on destroy (default 7-30 days)
}

resource "aws_secretsmanager_secret_version" "db_app" {
  secret_id = aws_secretsmanager_secret.db_app.id
  secret_string_wo = jsonencode({
    username = "retail_app"
    password = ephemeral.random_password.db_app.result
    host     = aws_db_instance.mysql.address
    port     = aws_db_instance.mysql.port
    dbname   = aws_db_instance.mysql.db_name
  })
  secret_string_wo_version = var.app_password_version
}
