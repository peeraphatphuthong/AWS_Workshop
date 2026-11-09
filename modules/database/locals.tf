locals {
  name_prefix  = var.name_prefix
  param_prefix = var.param_prefix

  # The identifier is needed before the instance exists (log group names), so build it here.
  db_identifier   = "${var.name_prefix}-mysql"
  rds_log_exports = ["error", "slowquery"]
}
