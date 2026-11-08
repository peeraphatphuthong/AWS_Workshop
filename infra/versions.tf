terraform {
  # >= 1.11 for write-only arguments (secret_string_wo) used in database.tf.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
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
