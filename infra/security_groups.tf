# Security groups are STATEFUL: if inbound traffic is allowed, the reply is allowed automatically.
# Rules are separate resources (aws_vpc_security_group_*_rule) instead of inline blocks —
# the current AWS provider recommendation: each rule has its own ID, tags, and clean diffs.

# ---------------------------------- Web tier ----------------------------------
resource "aws_security_group" "web" {
  # name_prefix (not name): create_before_destroy needs the new SG to coexist with the old one,
  # and SG names must be unique per VPC.
  name_prefix = "${local.name_prefix}-web-"
  description = "Web tier: HTTP/HTTPS from the internet"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-web-sg" }

  # Replacing an SG that is attached to an instance fails unless the new one exists first.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "web" {
  for_each = local.web_ingress_rules

  security_group_id = aws_security_group.web.id
  description       = each.value.description
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr

  tags = { Name = "${local.name_prefix}-web-in-${each.key}" }
}

# Outbound: the instance needs HTTPS to reach ECR, SSM, Secrets Manager, OS package repos.
resource "aws_vpc_security_group_egress_rule" "web_https_out" {
  security_group_id = aws_security_group.web.id
  description       = "HTTPS to the internet / AWS APIs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "web_http_out" {
  security_group_id = aws_security_group.web.id
  description       = "HTTP for OS package mirrors"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# Egress to the DB references the DB security group, not a CIDR.
resource "aws_vpc_security_group_egress_rule" "web_to_db" {
  security_group_id            = aws_security_group.web.id
  description                  = "MySQL to the database tier"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.db.id
}

# ---------------------------------- DB tier -----------------------------------
resource "aws_security_group" "db" {
  name_prefix = "${local.name_prefix}-db-"
  description = "Database tier: MySQL only from the web tier"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-db-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# SG-to-SG reference: "anything wearing the web SG may connect", regardless of its IP.
# Survives instance replacement / auto scaling without editing CIDRs.
resource "aws_vpc_security_group_ingress_rule" "db_from_web" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from web tier"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.web.id
}
# No egress rules on the DB SG: RDS answers connections (stateful) and never initiates any.
