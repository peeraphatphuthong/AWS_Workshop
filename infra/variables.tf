variable "aws_region" {
  description = "Region for all resources (sandbox only allows ap-southeast-2)."
  type        = string
  default     = "ap-southeast-2"
}

variable "project" {
  description = "Project name, used as a prefix for resource names."
  type        = string
  default     = "aws-workshop"
}

variable "environment" {
  description = "Environment name (dev / staging / prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC. /16 gives room for 256 x /24 subnets."
  type        = string
  default     = "10.20.0.0/16"

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
  description = "Inbound rules for the web tier security group."
  type = list(object({
    description = string
    port        = number
    cidr        = string
  }))
  default = [
    { description = "HTTP from anywhere", port = 80, cidr = "0.0.0.0/0" },
    { description = "HTTPS from anywhere", port = 443, cidr = "0.0.0.0/0" },
  ]
  # No port 22: shell access goes through SSM Session Manager (Phase 4).
}
