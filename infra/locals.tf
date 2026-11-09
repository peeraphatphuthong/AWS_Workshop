locals {
  name_prefix = "${var.project}-${var.environment}"

  # Parameter Store / Secrets Manager path for app settings of this environment.
  # (Names starting with "aws" or "ssm" are reserved by SSM, hence not "/aws-workshop/...".)
  param_prefix = "/retail-health/${var.environment}"

  # The web host lives in the first public subnet ("public-a"), with a fixed private IP (.50).
  web_subnet_key = "public-${substr(module.network.azs[0], -1, 1)}"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    Stack       = "infra"
    ManagedBy   = "Terraform"
    Repository  = "peeraphatphuthong/AWS_Workshop"
  }
}
