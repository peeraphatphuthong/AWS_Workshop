# Instance role: how the EC2 host gets AWS permissions WITHOUT any stored keys.
# The SDK/CLI on the instance fetches short-lived credentials from IMDS automatically.

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "web" {
  name               = "${local.name_prefix}-web"
  path               = "/${var.project}/" # CI user may only manage roles under this path
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# SSM Session Manager (shell without SSH/port 22) + Run Command (deployments in Phase 6).
resource "aws_iam_role_policy_attachment" "web_ssm" {
  role       = aws_iam_role.web.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Pull images from ECR.
resource "aws_iam_role_policy_attachment" "web_ecr" {
  role       = aws_iam_role.web.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Read this environment's app parameters (e.g. which image tag to run).
data "aws_iam_policy_document" "web_params" {
  statement {
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.param_prefix}/*",
    ]
  }
}

# Read DB credentials:
#  - app secret: used by deploy-app on every deploy
#  - master secret: used only by db-bootstrap to create/update the least-privilege app user.
#    Trade-off: the host could read the master password. Stricter alternative: run the bootstrap
#    from a short-lived Lambda/ECS task in the VPC and give the web role only the app secret.
data "aws_iam_policy_document" "web_db_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      var.db_app_secret_arn,
      var.db_master_secret_arn,
    ]
  }
}

resource "aws_iam_role_policy" "web_db_secrets" {
  name   = "read-db-secrets"
  role   = aws_iam_role.web.id
  policy = data.aws_iam_policy_document.web_db_secrets.json
}

resource "aws_iam_role_policy" "web_params" {
  name   = "read-app-parameters"
  role   = aws_iam_role.web.id
  policy = data.aws_iam_policy_document.web_params.json
}

# Write container logs (Docker awslogs driver runs in dockerd on the host and uses the instance role).
# Only into this stack's log group; the group itself is created by Terraform, not by the host.
data "aws_iam_policy_document" "web_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.containers.arn}:*"]
  }
}

resource "aws_iam_role_policy" "web_logs" {
  name   = "write-container-logs"
  role   = aws_iam_role.web.id
  policy = data.aws_iam_policy_document.web_logs.json
}

resource "aws_iam_instance_profile" "web" {
  name = "${local.name_prefix}-web"
  path = "/${var.project}/"
  role = aws_iam_role.web.name
}

data "aws_caller_identity" "current" {}
