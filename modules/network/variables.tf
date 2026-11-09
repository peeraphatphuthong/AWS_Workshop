variable "name_prefix" {
  description = "Prefix for resource names, e.g. aws-workshop-dev."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC. /16 gives room for 256 x /24 subnets."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "az_count" {
  description = "How many Availability Zones to spread subnets across (RDS needs >= 2)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "web_ingress" {
  description = "Inbound rules for the public load balancer (the only internet-facing entry point)."
  type = list(object({
    description = string
    port        = number
    cidr        = string
  }))
}
