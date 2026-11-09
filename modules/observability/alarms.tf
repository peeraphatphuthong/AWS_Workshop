# ------------------------------------------------------------------------------------------
# CloudWatch alarms + dashboard (Phase 7)
#
# Alert on symptoms users feel (site down, 5xx) and on causes we know will hurt (connection
# exhaustion, storage, CPU credits). 10 alarms = exactly the CloudWatch free tier.
#
# treat_missing_data = "notBreaching": at night the ASG scales to 0 and RDS is stopped, so their
# metrics simply stop. That is expected, not an outage, so missing data must not page anyone.
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
      description = "Web tier average CPU > 80% for 15 minutes (target tracking should already be scaling out)."
      namespace   = "AWS/EC2"
      metric      = "CPUUtilization"
      dimensions  = { AutoScalingGroupName = var.asg_name }
      statistic   = "Average"
      period      = 300
      periods     = 3
      operator    = "GreaterThanThreshold"
      threshold   = 80
    }
    "ec2-cpu-surplus-high" = {
      # Unlimited mode: surplus credits = CPU used above baseline that wasn't earned yet. Boot spends
      # a few; > 60 (one vCPU flat out for an hour) means sustained load that will show up on the bill.
      description = "Web instances spent > 60 surplus CPU credits (unlimited mode, billed at $0.05/vCPU-hour if not earned back)."
      namespace   = "AWS/EC2"
      metric      = "CPUSurplusCreditBalance"
      dimensions  = { AutoScalingGroupName = var.asg_name }
      statistic   = "Maximum"
      period      = 300
      periods     = 1
      operator    = "GreaterThanThreshold"
      threshold   = 60
    }
    # ---------------------------------------------------------------- ALB (Phase 8.3)
    "alb-unhealthy-hosts" = {
      # Replaces EC2 auto-recover: the ASG already replaces failed instances by itself; this tells
      # a human when it happens (or keeps happening — e.g. a bad AMI/user_data in a refresh).
      description = "At least one instance behind the ALB failed its health check for 3 minutes."
      namespace   = "AWS/ApplicationELB"
      metric      = "UnHealthyHostCount"
      dimensions  = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
      statistic   = "Maximum"
      period      = 60
      periods     = 3
      operator    = "GreaterThanThreshold"
      threshold   = 0
    }
    # ---------------------------------------------------------------- RDS
    "rds-cpu-high" = {
      description = "RDS CPU > 80% for 15 minutes."
      namespace   = "AWS/RDS"
      metric      = "CPUUtilization"
      dimensions  = { DBInstanceIdentifier = var.db_identifier }
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
      dimensions  = { DBInstanceIdentifier = var.db_identifier }
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
      dimensions  = { DBInstanceIdentifier = var.db_identifier }
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
      dimensions  = { DBInstanceIdentifier = var.db_identifier }
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

# ------------------------------------------------------------------------------------------
# Dashboard (first 3 dashboards are free): one page to look at during an incident.
# ------------------------------------------------------------------------------------------
locals {
  asg_dim = ["AutoScalingGroupName", var.asg_name]
  alb_dim = ["LoadBalancer", var.alb_arn_suffix]
  tg_dim  = ["TargetGroup", var.target_group_arn_suffix, "LoadBalancer", var.alb_arn_suffix]
  rds_dim = ["DBInstanceIdentifier", var.db_identifier]

  dashboard_widgets = [
    { title = "Health check (1 = OK)", metrics = [[local.metric_namespace, "HealthCheckOk", { stat = "Minimum" }]] },
    { title = "Health check latency (ms)", metrics = [[local.metric_namespace, "HealthCheckLatencyMs", { stat = "Average" }]] },
    { title = "Nginx 5xx", metrics = [[local.metric_namespace, "Nginx5xx", { stat = "Sum" }]] },
    { title = "ALB requests", metrics = [concat(["AWS/ApplicationELB", "RequestCount"], local.alb_dim, [{ stat = "Sum" }])] },
    { title = "ALB target response time (s)", metrics = [concat(["AWS/ApplicationELB", "TargetResponseTime"], local.alb_dim, [{ stat = "p95" }])] },
    { title = "Healthy / unhealthy targets", metrics = [concat(["AWS/ApplicationELB", "HealthyHostCount"], local.tg_dim, [{ stat = "Minimum" }]), concat(["AWS/ApplicationELB", "UnHealthyHostCount"], local.tg_dim, [{ stat = "Maximum" }])] },
    { title = "ASG instances in service", metrics = [concat(["AWS/AutoScaling", "GroupInServiceInstances"], local.asg_dim, [{ stat = "Maximum" }])] },
    { title = "Web CPU % (ASG average)", metrics = [concat(["AWS/EC2", "CPUUtilization"], local.asg_dim)] },
    { title = "Web CPU surplus credits", metrics = [concat(["AWS/EC2", "CPUSurplusCreditBalance"], local.asg_dim, [{ stat = "Maximum" }])] },
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
            query  = "SOURCE '${var.container_log_group_name}' | filter ispresent(status) | sort rt desc | fields @timestamp, status, method, uri, rt | limit 20"
            view   = "table"
          }
        },
      ],
    )
  })
}
