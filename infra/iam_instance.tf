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

resource "aws_iam_role_policy" "web_params" {
  name   = "read-app-parameters"
  role   = aws_iam_role.web.id
  policy = data.aws_iam_policy_document.web_params.json
}

resource "aws_iam_instance_profile" "web" {
  name = "${local.name_prefix}-web"
  path = "/${var.project}/"
  role = aws_iam_role.web.name
}

data "aws_caller_identity" "current" {}
