# ---------------------------------------------------------------------------------------------
# Account-level alert channel (Phase 7).
#
# Lives in bootstrap (admin-applied, local tfvars) instead of infra on purpose: the email address is
# personal data and the repository is public. Keeping it here means it never appears in CI logs,
# PR plan comments or plan artifacts. The infra stack finds the topic by name (data source).
#
# After the first apply AWS sends a "Subscription Confirmation" email -> click the link, otherwise
# the subscription stays "PendingConfirmation" and no alert is delivered.
# ---------------------------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
  # Not encrypted: CloudWatch alarms cannot publish to a topic encrypted with the AWS-managed
  # aws/sns key, and a customer-managed key costs $1/month. Alert text holds no secrets.
  # (Accepted in .trivyignore.yaml)
}

resource "aws_sns_topic_subscription" "alerts_email" {
  for_each = toset(var.budget_alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

data "aws_iam_policy_document" "alerts_topic" {
  # Keep the default "account owner can manage" behaviour.
  statement {
    sid = "AccountOwner"
    actions = [
      "sns:Publish", "sns:Subscribe", "sns:GetTopicAttributes", "sns:SetTopicAttributes",
      "sns:ListSubscriptionsByTopic", "sns:DeleteTopic", "sns:AddPermission", "sns:RemovePermission",
    ]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # AWS services that publish alerts. aws:SourceAccount prevents the "confused deputy" problem
  # (another account's alarm/budget publishing into our topic).
  statement {
    sid       = "AwsServicesPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "budgets.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}
