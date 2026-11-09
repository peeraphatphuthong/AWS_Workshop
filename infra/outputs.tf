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
  description = "Open this in a browser."
  value       = "http://${module.web.public_ip}"
}

output "web_public_eip" {
  value = module.web.public_ip
}

output "web_private_ip" {
  value = module.web.private_ip
}

output "web_instance_id" {
  value = module.web.instance_id
}

output "web_availability_zone" {
  value = module.web.availability_zone
}

output "ebs_volume_id" {
  value = module.web.ebs_volume_id
}

output "ssm_shell_command" {
  description = "Open a shell on the instance without SSH (needs the Session Manager plugin)."
  value       = "aws ssm start-session --target ${module.web.instance_id}"
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
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${module.observability.dashboard_name}"
}

output "container_log_group" {
  value = module.web.container_log_group_name
}

output "alarm_names" {
  value = module.observability.alarm_names
}

output "office_hours" {
  description = "When EC2/RDS are running (EventBridge Scheduler)."
  value       = var.office_hours.enabled ? "${var.office_hours.timezone}: RDS ${var.office_hours.start_db} -> web ${var.office_hours.start_web}; stop web ${var.office_hours.stop_web} -> RDS ${var.office_hours.stop_db}" : "disabled (always on)"
}
