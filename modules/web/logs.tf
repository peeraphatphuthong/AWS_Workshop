# ------------------------------------------------------------------------------------------
# CloudWatch Logs for the web host (Phase 7). Created by Terraform with a retention period:
# log groups that services create on their own default to "Never expire" (hidden cost).
# ------------------------------------------------------------------------------------------

# Containers on the web host (app + nginx). Docker's awslogs driver writes one stream per
# container (see /etc/docker/daemon.json in user_data).
resource "aws_cloudwatch_log_group" "containers" {
  name              = "${local.param_prefix}/containers"
  retention_in_days = var.log_retention_days
}
