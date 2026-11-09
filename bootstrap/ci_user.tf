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

# Two CI identities = two blast radii (the same split you'd do with two OIDC roles):
#   github-plan : READ-ONLY + state lock. Used by pull-request jobs (any branch).
#   github-ci   : write access to project resources. Used only by jobs on `main`
#                 (GitHub environments aws-dev / aws-dev-infra restrict branches + require approval).

resource "aws_iam_user" "github_ci" {
  name = "${var.project}-github-ci"
  path = "/ci/"
}

resource "aws_iam_user" "github_plan" {
  name = "${var.project}-github-plan"
  path = "/ci/"
}

# AWS-managed ReadOnlyAccess covers Describe/Get/List for every service `terraform plan` refreshes.
resource "aws_iam_user_policy_attachment" "github_plan_readonly" {
  user       = aws_iam_user.github_plan.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "github_plan" {
  # Plan takes the state lock (writes/deletes the .tflock object next to the state).
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn]
  }

  statement {
    sid       = "StateReadAndLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.tfstate.arn}/*"]
  }

  # Belt and braces: a PR job may only create/remove lock files, never overwrite state itself.
  # (ReadOnlyAccess does not include secretsmanager:GetSecretValue, so secret values stay unreadable.)
  statement {
    sid           = "DenyStateWritesOutsideLockFiles"
    effect        = "Deny"
    actions       = ["s3:PutObject", "s3:DeleteObject"]
    not_resources = ["${aws_s3_bucket.tfstate.arn}/*.tflock"]
  }
}

resource "aws_iam_policy" "github_plan" {
  name        = "${var.project}-github-plan"
  path        = "/ci/"
  description = "State lock access for ${var.github_repository} PR plan jobs; denies writes and secret reads"
  policy      = data.aws_iam_policy_document.github_plan.json
}

resource "aws_iam_user_policy_attachment" "github_plan" {
  user       = aws_iam_user.github_plan.name
  policy_arn = aws_iam_policy.github_plan.arn
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
      "ecs:*",
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

# Phase 8.4: create the ECS service-linked role here, ahead of time. In 8.3 the first apply failed
# because Auto Scaling created ITS service-linked role on first use and IAM had not propagated it
# yet ("Access denied when attempting to assume role ... AWSServiceRoleForAutoScaling").
# Creating account-level prerequisites in bootstrap avoids that race for ECS.
resource "aws_iam_service_linked_role" "ecs" {
  aws_service_name = "ecs.amazonaws.com"
  description      = "ECS service-linked role (created by bootstrap before the first Fargate service)"
}
