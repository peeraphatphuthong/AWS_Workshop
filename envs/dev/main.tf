# ------------------------------------------------------------------------------------------
# Environment: DEV (applied by CI after approval).
#
# Every environment is a thin root module: settings in `locals`, then the same four modules.
# `diff envs/dev/main.tf envs/prod/main.tf` shows exactly how the environments differ.
#
#   network ──subnets, SGs──► database ──secrets──► web ──instance, EIP, logs──► observability
# ------------------------------------------------------------------------------------------

locals {
  # ---- identity ----
  aws_region  = "ap-southeast-2"
  project     = "aws-workshop"
  environment = "dev"
  name_prefix = "${local.project}-${local.environment}"

  # Parameter Store / Secrets Manager path for app settings of this environment.
  # (Names starting with "aws" or "ssm" are reserved by SSM, hence not "/aws-workshop/...".)
  param_prefix = "/retail-health/${local.environment}"

  # ---- sizing & settings (dev = cheapest; see envs/prod for production values) ----
  vpc_cidr            = "10.20.0.0/16" # non-overlapping per env: dev 10.20, prod 10.40
  web_instance_type   = "t3.micro"
  data_volume_size_gb = 10
  db_instance_class   = "db.t4g.micro"
  log_retention_days  = 7

  # Stop EC2 + RDS at night (FinOps). Start the DB first, stop the web host first.
  office_hours = {
    enabled   = true
    timezone  = "Asia/Bangkok"
    start_db  = "cron(30 7 * * ? *)"  # 07:30
    start_web = "cron(0 8 * * ? *)"   # 08:00
    stop_web  = "cron(0 22 * * ? *)"  # 22:00
    stop_db   = "cron(10 22 * * ? *)" # 22:10
  }

  # No port 22: shell access goes through SSM Session Manager.
  web_ingress = [
    { description = "HTTP from anywhere", port = 80, cidr = "0.0.0.0/0" },
    { description = "HTTPS from anywhere", port = 443, cidr = "0.0.0.0/0" },
  ]

  # First image written to Parameter Store; CI/CD owns the value afterwards.
  initial_image_tag = "16c2953b8d1ae718fdb4714b421de3b45e2d98d5"

  # The web host lives in the first public subnet ("public-a"), with a fixed private IP (.50).
  web_subnet_key = "public-${substr(module.network.azs[0], -1, 1)}"

  common_tags = {
    Project     = local.project
    Environment = local.environment
    Stack       = "infra"
    ManagedBy   = "Terraform"
    Repository  = "peeraphatphuthong/AWS_Workshop"
  }
}

module "network" {
  source = "../../modules/network"

  name_prefix = local.name_prefix
  vpc_cidr    = local.vpc_cidr
  az_count    = 2
  web_ingress = local.web_ingress
}

module "database" {
  source = "../../modules/database"

  name_prefix          = local.name_prefix
  param_prefix         = local.param_prefix
  subnet_ids           = values(module.network.private_subnet_ids)
  security_group_id    = module.network.db_security_group_id
  instance_class       = local.db_instance_class
  app_password_version = 1 # increment to rotate the app DB password
  log_retention_days   = local.log_retention_days

  # Lab settings: single-AZ, 1-day backups, deletable without a final snapshot.
  multi_az              = false
  backup_retention_days = 1
  deletion_protection   = false
  skip_final_snapshot   = true
}

module "web" {
  source = "../../modules/web"

  project             = local.project
  name_prefix         = local.name_prefix
  param_prefix        = local.param_prefix
  aws_region          = local.aws_region
  subnet              = module.network.public_subnets[local.web_subnet_key]
  security_group_id   = module.network.web_security_group_id
  instance_type       = local.web_instance_type
  data_volume_size_gb = local.data_volume_size_gb
  initial_image_tag   = local.initial_image_tag
  ecr_repository_url  = aws_ecr_repository.app.repository_url
  ecr_repository_name = aws_ecr_repository.app.name

  db_app_secret_arn    = module.database.app_secret_arn
  db_master_secret_arn = module.database.master_secret_arn

  # Embedded in user_data: changing either file replaces the instance (user_data_replace_on_change).
  docker_compose_content = file("${path.root}/../../app/docker-compose.yml")
  nginx_conf_content     = file("${path.root}/../../app/nginx/nginx.conf")

  log_retention_days = local.log_retention_days
}

module "observability" {
  source = "../../modules/observability"

  project            = local.project
  name_prefix        = local.name_prefix
  environment        = local.environment
  aws_region         = local.aws_region
  alerts_topic_name  = "aws-workshop-alerts" # created by the bootstrap stack
  log_retention_days = local.log_retention_days
  office_hours       = local.office_hours
  health_check_rate  = "rate(5 minutes)"

  instance_id              = module.web.instance_id
  instance_arn             = module.web.instance_arn
  public_ip                = module.web.public_ip
  db_identifier            = module.database.identifier
  db_arn                   = module.database.arn
  container_log_group_name = module.web.container_log_group_name
}
