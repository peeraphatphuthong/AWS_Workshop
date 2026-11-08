# ------------------------------------------------------------------------------------------
# CloudWatch Logs (Phase 7)
#
# Every log group is created by Terraform with a retention period. Log groups that services
# create on their own (RDS exports, Lambda) default to "Never expire" — a classic hidden cost.
# Pre-creating them with the exact name the service expects puts retention under our control.
# ------------------------------------------------------------------------------------------

# Containers on the web host (app + nginx). Docker's awslogs driver writes one stream per
# container (see /etc/docker/daemon.json in user_data).
resource "aws_cloudwatch_log_group" "containers" {
  name              = "${local.param_prefix}/containers"
  retention_in_days = var.log_retention_days
}

# RDS log exports. The names are fixed by RDS: /aws/rds/instance/<identifier>/<log type>.
resource "aws_cloudwatch_log_group" "rds" {
  for_each = toset(local.rds_log_exports)

  name              = "/aws/rds/instance/${local.db_identifier}/${each.key}"
  retention_in_days = var.log_retention_days
}

# Turn nginx JSON access logs into a metric: number of 5xx responses.
# Metric filters are free; the metric is a custom metric ($0.30/month).
resource "aws_cloudwatch_log_metric_filter" "nginx_5xx" {
  name           = "nginx-5xx"
  log_group_name = aws_cloudwatch_log_group.containers.name
  pattern        = "{ $.status >= 500 }"

  metric_transformation {
    name          = "Nginx5xx"
    namespace     = local.metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}
