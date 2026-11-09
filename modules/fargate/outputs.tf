output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "service_name" {
  value = aws_ecs_service.app.name
}

output "service_arn" {
  value = aws_ecs_service.app.id
}

output "listener_port" {
  value = aws_lb_listener.app.port
}

output "target_group_arn_suffix" {
  description = "For CloudWatch metrics (dimension TargetGroup)."
  value       = aws_lb_target_group.app.arn_suffix
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.app.name
}
