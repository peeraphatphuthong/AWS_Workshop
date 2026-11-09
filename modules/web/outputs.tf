output "instance_id" {
  value = aws_instance.web.id
}

output "instance_arn" {
  value = aws_instance.web.arn
}

output "availability_zone" {
  value = aws_instance.web.availability_zone
}

output "private_ip" {
  value = aws_instance.web.private_ip
}

output "public_ip" {
  description = "Elastic IP of the web host."
  value       = aws_eip.web.public_ip
}

output "ebs_volume_id" {
  value = aws_ebs_volume.app_data.id
}

output "image_tag_parameter" {
  value = aws_ssm_parameter.image_tag.name
}

output "container_log_group_name" {
  value = aws_cloudwatch_log_group.containers.name
}
