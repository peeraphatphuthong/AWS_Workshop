data "aws_caller_identity" "current" {}

locals {
  name_prefix = var.name_prefix

  # Custom CloudWatch metrics (health check, nginx 5xx) live in this namespace.
  metric_namespace = "RetailHealth/${var.environment}"
}
