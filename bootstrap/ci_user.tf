# ---------------------------------------------------------------------------------------------
# CI identity for GitHub Actions.
#
# Preferred design: IAM OIDC provider for token.actions.githubusercontent.com + a role that only
# this repo can assume (short-lived credentials, nothing to leak). This sandbox's organization
# SCP explicitly denies iam:*OpenIDConnectProvider*, so we fall back to an IAM user with:
#   - least-privilege scope: one region, project IAM path only, state bucket only
#   - access key created OUTSIDE Terraform (scripts/rotate-ci-key.ps1) so the secret never
#     lands in Terraform state
#   - key stored as a GitHub *Environment* secret and rotated regularly
# ---------------------------------------------------------------------------------------------

resource "aws_iam_user" "github_ci" {
  name = "${var.project}-github-ci"
  path = "/ci/"
}

data "aws_iam_policy_document" "github_ci" {
  # 1) Terraform remote state: read/write objects in the state bucket only.
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetBucketVersioning"]
    resources = [aws_s3_bucket.tfstate.arn]
  }

  statement {
    sid       = "StateObjectsReadWrite"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.tfstate.arn}/*"]
  }

  # 2) Services the main stack manages — allowed ONLY in the project region.
  #    Service-level wildcards are a pragmatic start; tighten later with IAM Access Analyzer
  #    policy generation (based on what CloudTrail shows CI actually used).
  statement {
    sid = "ProjectServicesInRegion"
    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "autoscaling:*",
      "rds:*",
      "ecr:*",
      "ssm:*",
      "ec2messages:*",
      "ssmmessages:*",
      "secretsmanager:*",
      "cloudwatch:*",
      "logs:*",
      "sns:*",
      "scheduler:*",
      "events:*",
      "lambda:*",
      "kms:DescribeKey",
      "kms:ListAliases",
      "kms:CreateGrant",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  # 3) IAM is global and the most dangerous service: allow writes only under the project path.
  statement {
    sid = "IamWriteProjectPathOnly"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
      "iam:PassRole",
    ]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role${local.iam_path}*",
      "arn:${local.partition}:iam::${local.account_id}:instance-profile${local.iam_path}*",
      "arn:${local.partition}:iam::${local.account_id}:policy${local.iam_path}*",
    ]
  }

  # Service-linked roles (e.g. RDS, Auto Scaling) are created on first use of a service.
  statement {
    sid       = "IamServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/*"]
  }

  # Read-only IAM so `terraform plan` can refresh data sources and existing resources.
  statement {
    sid       = "IamReadOnly"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  # Global "who am I" / pricing lookups.
  statement {
    sid       = "GlobalReadOnly"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "github_ci" {
  name        = "${var.project}-github-ci"
  path        = "/ci/"
  description = "Least-privilege permissions for ${var.github_repository} GitHub Actions"
  policy      = data.aws_iam_policy_document.github_ci.json
}

resource "aws_iam_user_policy_attachment" "github_ci" {
  user       = aws_iam_user.github_ci.name
  policy_arn = aws_iam_policy.github_ci.arn
}
