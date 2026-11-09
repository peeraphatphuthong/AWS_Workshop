output "alb_dns_name" {
  description = "Public DNS name of the load balancer (the app URL)."
  value       = aws_lb.web.dns_name
}

output "alb_arn_suffix" {
  description = "For CloudWatch metrics (dimension LoadBalancer)."
  value       = aws_lb.web.arn_suffix
}

output "target_group_arn_suffix" {
  description = "For CloudWatch metrics (dimension TargetGroup)."
  value       = aws_lb_target_group.web.arn_suffix
}

output "asg_name" {
  value = aws_autoscaling_group.web.name
}

output "asg_arn" {
  value = aws_autoscaling_group.web.arn
}

output "image_tag_parameter" {
  value = aws_ssm_parameter.image_tag.name
}

output "container_log_group_name" {
  value = aws_cloudwatch_log_group.containers.name
}

output "alb_arn" {
  description = "Lets other modules add listeners to the same load balancer (Phase 8.4 Fargate)."
  value       = aws_lb.web.arn
}
