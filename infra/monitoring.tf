# ------------------------------------------------------------------------------------------
# CloudWatch alarms + dashboard (Phase 7)
#
# Alert on symptoms users feel (site down, 5xx) and on causes we know will hurt (connection
# exhaustion, storage, CPU credits). 10 alarms = exactly the CloudWatch free tier.
#
# treat_missing_data = "notBreaching": when the scheduler stops EC2/RDS at night their metrics
# simply stop. That is expected, not an outage, so missing data must not page anyone.
# ------------------------------------------------------------------------------------------

# Topic + email subscription live in the bootstrap stack (keeps the email out of this public repo/CI).
data "aws_sns_topic" "alerts" {
  name = var.alerts_topic_name
}

locals {
  alarm_actions = [data.aws_sns_topic.alerts.arn]

  # Simple threshold alarms in one map -> one resource block with for_each.
  metric_alarms = {
    # ---------------------------------------------------------------- EC2
    "ec2-cpu-high" = {
      description = "Web host CPU > 80% for 15 minutes."
      namespace   = "AWS/EC2"
      metric      = "CPUUtilization"
      dimensions  = { InstanceId = aws_instance.web.id }
      statistic   = "Average"
      period      = 300
      periods     = 3
      operator    = "GreaterThanThreshold"
      threshold   = 80
    }
    "ec2-cpu-surplus-high" = {
      # Unlimited mode: surplus credits = CPU used above baseline that wasn't earned yet. Boot spends
      # a few; > 60 (one vCPU flat out for an hour) means sustained load that will show up on the bill.
      description = "Web host spent > 60 surplus CPU credits (unlimited mode, billed at $0.05/vCPU-hour if not earned back)."
      namespace   = "AWS/EC2"
      metric      = "CPUSurplusCreditBalance"
      dimensions  = { InstanceId = aws_instance.web.id }
      statistic   = "Maximum"
      period      = 300
      periods     = 1
      operator    = "GreaterThanThreshold"
      threshold   = 60
    }
    # ---------------------------------------------------------------- RDS
    "rds-cpu-high" = {
      description = "RDS CPU > 80% for 15 minutes."
      namespace   = "AWS/RDS"
      metric      = "CPUUtilization"
      dimensions  = { DBInstanceIdentifier = aws_db_instance.mysql.identifier }
      statistic   = "Average"
      period      = 300
      periods     = 3
      operator    = "GreaterThanThreshold"
      threshold   = 80
    }
    "rds-connections-high" = {
      # db.t4g.micro max_connections is ~60 (derived from instance memory). The app pool holds 5.
      # 40 connections means something is leaking connections or too many app copies are running
      # — the Cloud SQL "too many connections" incident, caught BEFORE it becomes an outage.
      description = "RDS connections > 40 (pool leak / too many app instances; max is ~60)."
      namespace   = "AWS/RDS"
      metric      = "DatabaseConnections"
      dimensions  = { DBInstanceIdentifier = aws_db_instance.mysql.identifier }
      statistic   = "Maximum"
      period      = 300
      periods     = 2
      operator    = "GreaterThanThreshold"
      threshold   = 40
    }
    "rds-free-storage-low" = {
      description = "RDS free storage < 2 GiB (storage autoscaling is off)."
      namespace   = "AWS/RDS"
      metric      = "FreeStorageSpace"
      dimensions  = { DBInstanceIdentifier = aws_db_instance.mysql.identifier }
      statistic   = "Minimum"
      period      = 300
      periods     = 1
      operator    = "LessThanThreshold"
      threshold   = 2 * 1024 * 1024 * 1024
    }
    "rds-freeable-memory-low" = {
      description = "RDS freeable memory < 64 MiB (swapping / OOM risk on a 1 GiB instance)."
      namespace   = "AWS/RDS"
      metric      = "FreeableMemory"
      dimensions  = { DBInstanceIdentifier = aws_db_instance.mysql.identifier }
      statistic   = "Minimum"
      period      = 300
      periods     = 3
      operator    = "LessThanThreshold"
      threshold   = 64 * 1024 * 1024
    }
    # ---------------------------------------------------------------- App (custom metrics)
    "healthcheck-failed" = {
      description = "Synthetic check: GET /readyz on the public URL failed twice in a row."
      namespace   = local.metric_namespace
      metric      = "HealthCheckOk"
      dimensions  = {}
      statistic   = "Minimum"
      period      = 300
      periods     = 2
      operator    = "LessThanThreshold"
      threshold   = 1
    }
    "nginx-5xx" = {
      description = "5 or more HTTP 5xx responses in 5 minutes (from nginx access logs)."
      namespace   = local.metric_namespace
      metric      = "Nginx5xx"
      dimensions  = {}
      statistic   = "Sum"
      period      = 300
      periods     = 1
      operator    = "GreaterThanOrEqualToThreshold"
      threshold   = 5
    }
    "healthcheck-lambda-errors" = {
      description = "The health check Lambda itself is failing (otherwise a broken checker looks like 'all good')."
      namespace   = "AWS/Lambda"
      metric      = "Errors"
      dimensions  = { FunctionName = aws_lambda_function.healthcheck.function_name }
      statistic   = "Sum"
      period      = 300
      periods     = 3
      operator    = "GreaterThanOrEqualToThreshold"
      threshold   = 1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.metric_alarms

  alarm_name          = "${local.name_prefix}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  dimensions          = each.value.dimensions
  statistic           = each.value.statistic
  period              = each.value.period
  evaluation_periods  = each.value.periods
  comparison_operator = each.value.operator
  threshold           = each.value.threshold
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions # "resolved" email too, so you know when it's over
}

# Hardware/host failure on AWS's side: EC2 auto-recovery moves the instance to healthy hardware.
# Same instance ID, private IP, EIP and EBS volumes — no Terraform change needed.
resource "aws_cloudwatch_metric_alarm" "ec2_auto_recover" {
  alarm_name          = "${local.name_prefix}-ec2-system-check-failed"
  alarm_description   = "AWS system status check failed -> auto-recover the web host onto new hardware."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = aws_instance.web.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = concat(["arn:aws:automate:${var.aws_region}:ec2:recover"], local.alarm_actions)
  ok_actions    = local.alarm_actions
}

# ------------------------------------------------------------------------------------------
# Dashboard (first 3 dashboards are free): one page to look at during an incident.
# ------------------------------------------------------------------------------------------
locals {
  ec2_dim = ["InstanceId", aws_instance.web.id]
  rds_dim = ["DBInstanceIdentifier", aws_db_instance.mysql.identifier]

  dashboard_widgets = [
    { title = "Health check (1 = OK)", metrics = [[local.metric_namespace, "HealthCheckOk", { stat = "Minimum" }]] },
    { title = "Health check latency (ms)", metrics = [[local.metric_namespace, "HealthCheckLatencyMs", { stat = "Average" }]] },
    { title = "Nginx 5xx", metrics = [[local.metric_namespace, "Nginx5xx", { stat = "Sum" }]] },
    { title = "EC2 CPU %", metrics = [concat(["AWS/EC2", "CPUUtilization"], local.ec2_dim)] },
    { title = "EC2 CPU credit balance", metrics = [concat(["AWS/EC2", "CPUCreditBalance"], local.ec2_dim)] },
    { title = "RDS connections", metrics = [concat(["AWS/RDS", "DatabaseConnections"], local.rds_dim, [{ stat = "Maximum" }])] },
    { title = "RDS CPU %", metrics = [concat(["AWS/RDS", "CPUUtilization"], local.rds_dim)] },
    { title = "RDS freeable memory", metrics = [concat(["AWS/RDS", "FreeableMemory"], local.rds_dim)] },
    { title = "RDS read/write latency (s)", metrics = [concat(["AWS/RDS", "ReadLatency"], local.rds_dim), concat(["AWS/RDS", "WriteLatency"], local.rds_dim)] },
  ]
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = local.name_prefix
  dashboard_body = jsonencode({
    widgets = concat(
      [
        for i, w in local.dashboard_widgets : {
          type   = "metric"
          x      = (i % 3) * 8
          y      = floor(i / 3) * 6
          width  = 8
          height = 6
          properties = {
            title   = w.title
            region  = var.aws_region
            metrics = w.metrics
            period  = 300
            stat    = "Average"
            view    = "timeSeries"
          }
        }
      ],
      [
        {
          type   = "log"
          x      = 0
          y      = ceil(length(local.dashboard_widgets) / 3) * 6
          width  = 24
          height = 6
          properties = {
            title  = "Slowest requests (nginx, last 3h)"
            region = var.aws_region
            query  = "SOURCE '${aws_cloudwatch_log_group.containers.name}' | filter ispresent(status) | sort rt desc | fields @timestamp, status, method, uri, rt | limit 20"
            view   = "table"
          }
        },
      ],
    )
  })
}
