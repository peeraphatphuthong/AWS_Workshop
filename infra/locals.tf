data "aws_availability_zones" "available" {
  state = "available"

  # Skip Local Zones / Wavelength zones — only regular AZs.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name_prefix = "${var.project}-${var.environment}"

  # Take the first N AZs instead of hard-coding "ap-southeast-2a" etc.
  azs = slice(sort(data.aws_availability_zones.available.names), 0, var.az_count)

  # Build the subnet map with `for` expressions.
  #   cidrsubnet("10.20.0.0/16", 8, n) -> 10.20.n.0/24
  #   public  subnets: 10.20.1.0/24, 10.20.2.0/24 ...
  #   private subnets: 10.20.11.0/24, 10.20.12.0/24 ...
  # Keys are stable names ("public-a"), so adding/removing an AZ never renumbers other subnets
  # (the classic `count` index-shift problem).
  public_subnets = {
    for idx, az in local.azs : "public-${substr(az, -1, 1)}" => {
      az   = az
      cidr = cidrsubnet(var.vpc_cidr, 8, idx + 1)
      tier = "public"
    }
  }

  private_subnets = {
    for idx, az in local.azs : "private-${substr(az, -1, 1)}" => {
      az   = az
      cidr = cidrsubnet(var.vpc_cidr, 8, idx + 11)
      tier = "private"
    }
  }

  subnets = merge(local.public_subnets, local.private_subnets)

  # list(object) -> map, keyed by something unique, so it can feed for_each.
  web_ingress_rules = {
    for rule in var.web_ingress : "${rule.port}-${rule.cidr}" => rule
  }

  common_tags = {
    Project     = var.project
    Environment = var.environment
    Stack       = "infra"
    ManagedBy   = "Terraform"
    Repository  = "peeraphatphuthong/AWS_Workshop"
  }
}
