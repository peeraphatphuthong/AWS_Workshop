output "state_bucket_name" {
  description = "S3 bucket for Terraform remote state."
  value       = aws_s3_bucket.tfstate.bucket
}

output "aws_region" {
  value = local.region
}

output "github_ci_user_name" {
  description = "IAM user used by GitHub Actions (create its key with scripts/rotate-ci-key.ps1)."
  value       = aws_iam_user.github_ci.name
}

output "github_plan_user_name" {
  description = "Read-only IAM user for pull-request plan jobs."
  value       = aws_iam_user.github_plan.name
}

output "project_iam_path" {
  description = "IAM path the main stack must use for roles / instance profiles."
  value       = local.iam_path
}
