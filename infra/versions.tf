terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Same bucket as bootstrap, different key = separate state per stack (smaller blast radius).
  backend "s3" {
    bucket       = "aws-workshop-tfstate-525091405764-ap-southeast-2"
    key          = "infra/terraform.tfstate"
    region       = "ap-southeast-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
