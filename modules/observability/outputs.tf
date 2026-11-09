output "dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}

output "alarm_names" {
  value = concat([for a in aws_cloudwatch_metric_alarm.this : a.alarm_name], [aws_cloudwatch_metric_alarm.ec2_auto_recover.alarm_name])
}
