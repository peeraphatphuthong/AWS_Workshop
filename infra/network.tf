resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # Needed so instances get DNS names and RDS endpoints / VPC endpoints resolve inside the VPC.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-igw" }
}

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  # We attach an Elastic IP explicitly in Phase 4, so no auto-assigned public IPs
  # (each public IPv4 costs ~$3.6/month and is easy to forget).
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-${each.key}"
    Tier = each.value.tier
  }
}

# ---- Public routing: default route to the Internet Gateway ----
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each = local.public_subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.public.id
}

# ---- Private routing: local VPC traffic only (no NAT Gateway — saves ~$45/month) ----
# RDS doesn't need internet access. If private workloads needed outbound access later,
# options are: NAT Gateway ($$), NAT instance ($), or VPC endpoints for specific AWS services.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-private-rt" }
}

resource "aws_route_table_association" "private" {
  for_each = local.private_subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.private.id
}

# Every VPC gets a "default" SG that allows all traffic between its members.
# Taking it over with no rules means nothing can accidentally use it (CIS benchmark 5.4).
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-default-sg-locked" }
}
