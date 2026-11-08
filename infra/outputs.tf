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
