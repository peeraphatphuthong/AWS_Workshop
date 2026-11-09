# ------------------------------------------------------------------------------------------
# Environment: DEV (applied by CI after approval).
#
# Every environment is a thin root module: settings in `locals`, then the same four modules.
# `diff envs/dev/main.tf envs/prod/main.tf` shows exactly how the environments differ.
#
#   network ──subnets, SGs──► database ──secrets──► web ──ALB, ASG, logs──► observability
#                                                     └──ALB──► fargate (8.4) ──┘
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
  vpc_cidr           = "10.20.0.0/16" # non-overlapping per env: dev 10.20, prod 10.40
  web_instance_type  = "t3.micro"
  web_min_size       = 1 # ASG minimum during office hours (1 instance, max 2)
  db_instance_class  = "db.t4g.micro"
  log_retention_days = 7

  # Stop EC2 + RDS at night (FinOps). Start the DB first, stop the web host first.
  office_hours = {
    enabled   = true
    timezone  = "Asia/Bangkok"
    start_db  = "cron(30 7 * * ? *)"  # 07:30
    start_web = "cron(0 8 * * ? *)"   # 08:00
    stop_web  = "cron(0 22 * * ? *)"  # 22:00
    stop_db   = "cron(10 22 * * ? *)" # 22:10
  }

  # Internet -> ALB only (instances accept the ALB's security group, nothing else; no port 22).
  # HTTPS would need an ACM certificate for a domain, which this sandbox doesn't have.
  web_ingress = [
    { description = "HTTP from anywhere", port = 80, cidr = "0.0.0.0/0" },
  ]

  # First image written to Parameter Store; CI/CD owns the value afterwards.
  initial_image_tag = "16c2953b8d1ae718fdb4714b421de3b45e2d98d5"

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

  project               = local.project
  name_prefix           = local.name_prefix
  param_prefix          = local.param_prefix
  aws_region            = local.aws_region
  vpc_id                = module.network.vpc_id
  subnets               = module.network.public_subnets # ALB + ASG across all AZs
  alb_security_group_id = module.network.alb_security_group_id
  security_group_id     = module.network.web_security_group_id
  instance_type         = local.web_instance_type
  min_size              = local.web_min_size
  max_size              = 2
  initial_image_tag     = local.initial_image_tag
  ecr_repository_url    = aws_ecr_repository.app.repository_url
  ecr_repository_name   = aws_ecr_repository.app.name

  db_app_secret_arn    = module.database.app_secret_arn
  db_master_secret_arn = module.database.master_secret_arn

  # Embedded in user_data: changing either file creates a new launch template version -> instance refresh.
  docker_compose_content = file("${path.root}/../../app/docker-compose.yml")
  nginx_conf_content     = file("${path.root}/../../app/nginx/nginx.conf")

  log_retention_days = local.log_retention_days
}

# Phase 8.4: the same image on ECS Fargate, behind the same ALB on port 8080, using the same DB.
# Dev only (a comparison lab): delete this block to remove every Fargate resource.
module "fargate" {
  source = "../../modules/fargate"

  project      = local.project
  name_prefix  = local.name_prefix
  param_prefix = local.param_prefix
  aws_region   = local.aws_region
  vpc_id       = module.network.vpc_id
  subnet_ids   = [for s in module.network.public_subnets : s.id]

  alb_arn               = module.web.alb_arn
  alb_security_group_id = module.network.alb_security_group_id
  db_security_group_id  = module.network.db_security_group_id
  db_app_secret_arn     = module.database.app_secret_arn
  ecr_repository_url    = aws_ecr_repository.app.repository_url
  image_tag_parameter   = module.web.image_tag_parameter

  listener_port      = 8080
  desired_count      = 1
  use_spot           = true # dev: ~70% cheaper, a Spot interruption just restarts the task
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

  asg_name                 = module.web.asg_name
  asg_arn                  = module.web.asg_arn
  web_min_size             = local.web_min_size
  app_host                 = module.web.alb_dns_name
  alb_arn_suffix           = module.web.alb_arn_suffix
  target_group_arn_suffix  = module.web.target_group_arn_suffix
  db_identifier            = module.database.identifier
  db_arn                   = module.database.arn
  container_log_group_name = module.web.container_log_group_name

  fargate = {
    cluster_name            = module.fargate.cluster_name
    service_name            = module.fargate.service_name
    service_arn             = module.fargate.service_arn
    desired_count           = 1
    target_group_arn_suffix = module.fargate.target_group_arn_suffix
  }
}
