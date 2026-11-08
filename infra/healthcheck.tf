# ------------------------------------------------------------------------------------------
# Synthetic health check (Phase 7)
#
# Why not Route 53 health checks? Their metrics only exist in us-east-1, which this sandbox's SCP
# blocks. CloudWatch Synthetics canaries cost ~$10/month at a 5-minute rate. A tiny Lambda on a
# schedule does the same job inside the free tier (~8,600 invocations/month).
# ------------------------------------------------------------------------------------------

locals {
  healthcheck_name = "${local.name_prefix}-healthcheck"
}

# Zip is built during plan. CI uploads infra/.build together with the saved plan so the apply job
# (a different runner) uploads exactly the same file. archive_file output is deterministic.
data "archive_file" "healthcheck" {
  type        = "zip"
  source_file = "${path.module}/lambda/healthcheck.py"
  output_path = "${path.module}/.build/healthcheck.zip"
  # Fixed permissions: a zip built on Windows otherwise differs from one built on Linux (CI), which
  # shows up as a fake source_code_hash diff when planning from a laptop.
  output_file_mode = "0644"
}

resource "aws_cloudwatch_log_group" "healthcheck" {
  name              = "/aws/lambda/${local.healthcheck_name}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "healthcheck" {
  name               = local.healthcheck_name
  path               = "/${var.project}/"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "healthcheck" {
  statement {
    sid       = "OwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.healthcheck.arn}:*"]
  }

  # PutMetricData has no resource ARN; the namespace condition is the only way to scope it.
  statement {
    sid       = "PublishOwnMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.metric_namespace]
    }
  }

  # Describe* calls do not support resource-level permissions.
  statement {
    sid       = "ReadInstanceState"
    actions   = ["ec2:DescribeInstanceStatus"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "healthcheck" {
  name   = "healthcheck"
  role   = aws_iam_role.healthcheck.id
  policy = data.aws_iam_policy_document.healthcheck.json
}

resource "aws_lambda_function" "healthcheck" {
  function_name    = local.healthcheck_name
  description      = "GET /readyz on the public URL and publish HealthCheckOk / latency metrics"
  role             = aws_iam_role.healthcheck.arn
  runtime          = "python3.13"
  architectures    = ["arm64"] # Graviton: ~20% cheaper per GB-second
  handler          = "healthcheck.handler"
  filename         = data.archive_file.healthcheck.output_path
  source_code_hash = data.archive_file.healthcheck.output_base64sha256
  memory_size      = 128
  timeout          = 15

  environment {
    variables = {
      URL         = "http://${aws_eip.web.public_ip}/readyz"
      INSTANCE_ID = aws_instance.web.id
      NAMESPACE   = local.metric_namespace
    }
  }

  depends_on = [aws_cloudwatch_log_group.healthcheck, aws_iam_role_policy.healthcheck]
}
