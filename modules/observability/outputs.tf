output "dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}

output "alarm_names" {
  value = [for a in aws_cloudwatch_metric_alarm.this : a.alarm_name]
}
