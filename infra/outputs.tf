output "vpc_id" {
  value = aws_vpc.main.id
}

output "azs" {
  description = "Availability Zones in use."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Map of public subnet name => ID."
  value       = { for k, _ in local.public_subnets : k => aws_subnet.this[k].id }
}

output "private_subnet_ids" {
  description = "Map of private subnet name => ID."
  value       = { for k, _ in local.private_subnets : k => aws_subnet.this[k].id }
}

output "subnet_cidrs" {
  description = "Subnet name => CIDR (handy to see what cidrsubnet() produced)."
  value       = { for k, s in local.subnets : k => s.cidr }
}

output "web_security_group_id" {
  value = aws_security_group.web.id
}

output "db_security_group_id" {
  value = aws_security_group.db.id
}

output "web_url" {
  description = "Open this in a browser."
  value       = "http://${aws_eip.web.public_ip}"
}

output "web_public_eip" {
  value = aws_eip.web.public_ip
}

output "web_private_ip" {
  value = aws_instance.web.private_ip
}

output "web_instance_id" {
  value = aws_instance.web.id
}

output "web_availability_zone" {
  value = aws_instance.web.availability_zone
}

output "ebs_volume_id" {
  value = aws_ebs_volume.app_data.id
}

output "ssm_shell_command" {
  description = "Open a shell on the instance without SSH (needs the Session Manager plugin)."
  value       = "aws ssm start-session --target ${aws_instance.web.id}"
}

output "image_tag_parameter" {
  value = aws_ssm_parameter.image_tag.name
}

output "rds_endpoint" {
  description = "Private DNS name of the MySQL instance (resolvable only inside the VPC)."
  value       = aws_db_instance.mysql.address
}

output "rds_master_secret_arn" {
  value = aws_db_instance.mysql.master_user_secret[0].secret_arn
}

output "db_app_secret_name" {
  value = aws_secretsmanager_secret.db_app.name
}

output "ecr_repository_url" {
  description = "Push/pull URL of the app image repository."
  value       = aws_ecr_repository.app.repository_url
}

output "dashboard_url" {
  description = "CloudWatch dashboard for this environment."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "container_log_group" {
  value = aws_cloudwatch_log_group.containers.name
}

output "alarm_names" {
  value = concat([for a in aws_cloudwatch_metric_alarm.this : a.alarm_name], [aws_cloudwatch_metric_alarm.ec2_auto_recover.alarm_name])
}

output "office_hours" {
  description = "When EC2/RDS are running (EventBridge Scheduler)."
  value       = var.office_hours.enabled ? "${var.office_hours.timezone}: RDS ${var.office_hours.start_db} -> web ${var.office_hours.start_web}; stop web ${var.office_hours.stop_web} -> RDS ${var.office_hours.stop_db}" : "disabled (always on)"
}
