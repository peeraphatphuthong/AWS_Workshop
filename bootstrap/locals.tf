locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  # S3 bucket names are global across ALL AWS accounts, so include account ID + region for uniqueness.
  state_bucket_name = "${var.project}-tfstate-${local.account_id}-${local.region}"

  # Every IAM role/instance profile/policy created by the main stack lives under this path.
  # The CI user may only manage IAM entities under it — a simple, effective permission boundary.
  iam_path = "/${var.project}/"

  common_tags = {
    Project    = var.project
    Stack      = "bootstrap"
    ManagedBy  = "Terraform"
    Repository = var.github_repository
  }
}
