output "vpc_id" {
  value = module.network.vpc_id
}

output "azs" {
  description = "Availability Zones in use."
  value       = module.network.azs
}

output "public_subnet_ids" {
  description = "Map of public subnet name => ID."
  value       = { for k, s in module.network.public_subnets : k => s.id }
}

output "private_subnet_ids" {
  description = "Map of private subnet name => ID."
  value       = module.network.private_subnet_ids
}

output "alb_security_group_id" {
  value = module.network.alb_security_group_id
}

output "web_security_group_id" {
  value = module.network.web_security_group_id
}

output "db_security_group_id" {
  value = module.network.db_security_group_id
}

output "subnet_cidrs" {
  description = "Subnet name => CIDR (handy to see what cidrsubnet() produced)."
  value       = module.network.subnet_cidrs
}

output "web_url" {
  description = "Open this in a browser (the load balancer)."
  value       = "http://${module.web.alb_dns_name}"
}

output "web_asg_name" {
  value = module.web.asg_name
}

output "ssm_shell_hint" {
  description = "Instances come and go; find one, then open a shell without SSH."
  value       = "aws ec2 describe-instances --filters Name=tag:aws:autoscaling:groupName,Values=${module.web.asg_name} Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text  # then: aws ssm start-session --target <id>"
}

output "image_tag_parameter" {
  value = module.web.image_tag_parameter
}

output "rds_endpoint" {
  description = "Private DNS name of the MySQL instance (resolvable only inside the VPC)."
  value       = module.database.address
}

output "rds_master_secret_arn" {
  value = module.database.master_secret_arn
}

output "db_app_secret_name" {
  value = module.database.app_secret_name
}

output "ecr_repository_url" {
  description = "Push/pull URL of the app image repository."
  value       = aws_ecr_repository.app.repository_url
}

output "dashboard_url" {
  description = "CloudWatch dashboard for this environment."
  value       = "https://${local.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${local.aws_region}#dashboards/dashboard/${module.observability.dashboard_name}"
}

output "container_log_group" {
  value = module.web.container_log_group_name
}

output "alarm_names" {
  value = module.observability.alarm_names
}

output "office_hours" {
  description = "When the web tier (EC2 + Fargate) and RDS are running (EventBridge Scheduler)."
  value       = local.office_hours.enabled ? "${local.office_hours.timezone}: RDS ${local.office_hours.start_db} -> web ${local.office_hours.start_web}; stop web ${local.office_hours.stop_web} -> RDS ${local.office_hours.stop_db}" : "disabled (always on)"
}

output "fargate_url" {
  description = "Phase 8.4: the same app on ECS Fargate (same ALB, port 8080)."
  value       = "http://${module.web.alb_dns_name}:${module.fargate.listener_port}"
}

output "fargate_service" {
  value = "${module.fargate.cluster_name}/${module.fargate.service_name}"
}

output "fargate_events_log_group" {
  description = "Why Fargate tasks stopped (stopCode, stoppedReason), deployments, service actions."
  value       = module.fargate.events_log_group_name
}
