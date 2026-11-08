# ------------------------------------------------------------------------------------------
# EventBridge Scheduler (Phase 7)
#   - office hours: stop EC2 + RDS at night, start them in the morning (FinOps)
#   - health check: invoke the Lambda every few minutes
#
# "Universal targets" (arn:aws:scheduler:::aws-sdk:<service>:<apiAction>) call AWS APIs directly,
# so no Lambda is needed just to stop an instance. Scheduler assumes the role below to do it.
#
# Side effects to know about while the stack is "asleep":
#   - the app deploy job fails (no running instance) -> re-run it in the morning
#   - RDS cannot be modified while stopped -> an apply that changes RDS must wait for office hours
#   - AWS auto-starts a stopped RDS instance after 7 days (the daily stop handles it)
# ------------------------------------------------------------------------------------------

resource "aws_scheduler_schedule_group" "main" {
  name = local.name_prefix
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    # Only schedules in THIS account may use the role (confused-deputy protection).
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name_prefix}-scheduler"
  path               = "/${var.project}/"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

# Least privilege: only start/stop THIS instance and THIS database, invoke THIS function.
data "aws_iam_policy_document" "scheduler" {
  statement {
    sid       = "StartStopWebHost"
    actions   = ["ec2:StartInstances", "ec2:StopInstances"]
    resources = [aws_instance.web.arn]
  }

  statement {
    sid       = "StartStopDatabase"
    actions   = ["rds:StartDBInstance", "rds:StopDBInstance"]
    resources = [aws_db_instance.mysql.arn]
  }

  statement {
    sid       = "InvokeHealthCheck"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.healthcheck.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "scheduler-targets"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

locals {
  office_hours_schedules = {
    "start-db" = {
      cron   = var.office_hours.start_db
      target = "arn:aws:scheduler:::aws-sdk:rds:startDBInstance"
      input  = { DbInstanceIdentifier = aws_db_instance.mysql.identifier }
    }
    "start-web" = {
      cron   = var.office_hours.start_web
      target = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
      input  = { InstanceIds = [aws_instance.web.id] }
    }
    "stop-web" = {
      cron   = var.office_hours.stop_web
      target = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
      input  = { InstanceIds = [aws_instance.web.id] }
    }
    "stop-db" = {
      cron   = var.office_hours.stop_db
      target = "arn:aws:scheduler:::aws-sdk:rds:stopDBInstance"
      input  = { DbInstanceIdentifier = aws_db_instance.mysql.identifier }
    }
  }
}

resource "aws_scheduler_schedule" "office_hours" {
  for_each = local.office_hours_schedules

  name                         = each.key
  group_name                   = aws_scheduler_schedule_group.main.name
  description                  = "Office hours (${var.office_hours.timezone}): ${each.key}"
  schedule_expression          = each.value.cron
  schedule_expression_timezone = var.office_hours.timezone
  state                        = var.office_hours.enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = each.value.target
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode(each.value.input)

    retry_policy {
      maximum_retry_attempts = 3
    }
  }

  depends_on = [aws_iam_role_policy.scheduler]
}

resource "aws_scheduler_schedule" "healthcheck" {
  name                = "healthcheck"
  group_name          = aws_scheduler_schedule_group.main.name
  description         = "Synthetic health check of the public URL"
  schedule_expression = var.health_check_rate

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.healthcheck.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ source = "scheduler" })

    retry_policy {
      maximum_retry_attempts = 0 # next run is in a few minutes anyway
    }
  }

  depends_on = [aws_iam_role_policy.scheduler]
}
