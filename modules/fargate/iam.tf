# ECS uses two different roles — a frequent source of confusion:
#
#   execution role : used by the ECS AGENT before the container starts (pull the image from ECR,
#                    create the log stream, fetch `secrets` from Secrets Manager into env vars).
#   task role      : used by the APP inside the container for its own AWS API calls
#                    (the Fargate equivalent of the EC2 instance profile).
#
# This app makes no AWS API calls on Fargate (IMDS is disabled, the DB password arrives as an env
# var), so there is NO task role: least privilege means not granting what isn't used.
# Compare: the EC2 instance role needs SSM, ECR, Parameter Store, both DB secrets and Logs.

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    # Confused-deputy protection: only ECS in this account may assume the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-fargate-execution"
  path               = "/${var.project}/" # CI user may only manage roles under this path
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# ECR pull + CloudWatch Logs.
resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Only the APP secret. The EC2 host can also read the master secret (it runs db-bootstrap);
# Fargate reuses the app user that bootstrap created, so it never needs the master password.
data "aws_iam_policy_document" "execution_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_app_secret_arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-app-db-secret"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

data "aws_caller_identity" "current" {}
