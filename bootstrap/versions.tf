terraform {
  # >= 1.10 is required for S3 native state locking (use_lockfile), no DynamoDB table needed.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Tags applied to every resource this provider creates — consistent tagging is the
  # foundation of cost allocation (FinOps) and ownership tracking.
  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}
