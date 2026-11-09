# RDS log exports (Phase 7). Pre-created with the exact names RDS uses so they get a retention
# period instead of "Never expire".
# Names are fixed by RDS: /aws/rds/instance/<identifier>/<log type>.
resource "aws_cloudwatch_log_group" "rds" {
  for_each = toset(local.rds_log_exports)

  name              = "/aws/rds/instance/${local.db_identifier}/${each.key}"
  retention_in_days = var.log_retention_days
}
