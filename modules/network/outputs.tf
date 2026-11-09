output "vpc_id" {
  value = aws_vpc.main.id
}

output "azs" {
  description = "Availability Zones in use."
  value       = local.azs
}

output "public_subnets" {
  description = "Public subnets: name => { id, az, cidr }."
  value = {
    for k, s in local.public_subnets : k => { id = aws_subnet.this[k].id, az = s.az, cidr = s.cidr }
  }
  # A public subnet is only useful once it routes to the internet. Consumers (EC2 + EIP) wait for
  # the IGW and the default route without having to know about them.
  depends_on = [aws_internet_gateway.main, aws_route.public_internet]
}

output "private_subnet_ids" {
  description = "Private subnets: name => ID."
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

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}
