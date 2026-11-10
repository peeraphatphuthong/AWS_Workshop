# ------------------------------------------------------------------------------------------
# ECS events -> CloudWatch Logs: WHY did a task stop?
#
# Follow-up to 2026-11-10: the Fargate task was replaced twice without a deploy (08:42, 12:46),
# probably Spot interruptions, but ECS keeps stopped tasks for only ~1 hour, so the reason
# (stopCode / stoppedReason) was gone when we looked. EventBridge receives every state change
# for free; these rules keep the interesting ones for log_retention_days.
#
#   Logs Insights:  fields @timestamp, detail.stopCode, detail.stoppedReason, detail.taskArn
#                   | filter `detail-type` = "ECS Task State Change" | sort @timestamp desc
# ------------------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "ecs_events" {
  # EventBridge -> Logs targets conventionally live under /aws/events/.
  name              = "/aws/events/${var.name_prefix}-ecs"
  retention_in_days = var.log_retention_days
}

# Tasks of THIS cluster reaching STOPPED (stopCode: SpotInterruption, TaskFailedToStart,
# EssentialContainerExited, ServiceSchedulerInitiated, ...). Running/pending transitions are skipped.
resource "aws_cloudwatch_event_rule" "task_stopped" {
  name        = "${var.name_prefix}-ecs-task-stopped"
  description = "ECS tasks of ${aws_ecs_cluster.main.name} that stopped (keeps stopCode/stoppedReason)"
  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change"]
    detail = {
      clusterArn = [aws_ecs_cluster.main.arn]
      lastStatus = ["STOPPED"]
    }
  })
}

# Deployments (IN_PROGRESS / COMPLETED / FAILED, incl. circuit-breaker rollbacks) and service actions
# (e.g. SERVICE_TASK_PLACEMENT_FAILURE when Spot capacity is unavailable) of THIS service.
resource "aws_cloudwatch_event_rule" "service_events" {
  name        = "${var.name_prefix}-ecs-service-events"
  description = "Deployment state changes and service actions of ${aws_ecs_service.app.name}"
  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Deployment State Change", "ECS Service Action"]
    resources     = [aws_ecs_service.app.id]
  })
}

resource "aws_cloudwatch_event_target" "ecs_events" {
  for_each = {
    task_stopped   = aws_cloudwatch_event_rule.task_stopped.name
    service_events = aws_cloudwatch_event_rule.service_events.name
  }

  rule = each.value
  arn  = aws_cloudwatch_log_group.ecs_events.arn

  depends_on = [aws_cloudwatch_log_resource_policy.ecs_events]
}

# A Logs target has no IAM role: the log group's RESOURCE policy must allow EventBridge to write.
# Scoped to this log group and to rules in this account.
data "aws_iam_policy_document" "ecs_events_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.ecs_events.arn}:*"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values = [
        aws_cloudwatch_event_rule.task_stopped.arn,
        aws_cloudwatch_event_rule.service_events.arn,
      ]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "ecs_events" {
  policy_name     = "${var.name_prefix}-ecs-events"
  policy_document = data.aws_iam_policy_document.ecs_events_logs.json
}
