# ------------------------------------------------------------------------------------------
# Root module of the dev environment (Phase 8): wiring only.
# Each module owns one concern and talks to the others through inputs/outputs:
#
#   network ──subnets, SGs──► database ──secrets──► web ──instance, EIP, logs──► observability
#
# The resources themselves did not change when they moved into modules: moved.tf tells
# Terraform the old and new addresses, so the plan shows 0 to add / 0 to destroy.
# ------------------------------------------------------------------------------------------

module "network" {
  source = "../modules/network"

  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr
  az_count    = var.az_count
  web_ingress = var.web_ingress
}

module "database" {
  source = "../modules/database"

  name_prefix          = local.name_prefix
  param_prefix         = local.param_prefix
  subnet_ids           = values(module.network.private_subnet_ids)
  security_group_id    = module.network.db_security_group_id
  instance_class       = var.db_instance_class
  app_password_version = var.db_app_password_version
  log_retention_days   = var.log_retention_days
}

module "web" {
  source = "../modules/web"

  project             = var.project
  name_prefix         = local.name_prefix
  param_prefix        = local.param_prefix
  aws_region          = var.aws_region
  subnet              = module.network.public_subnets[local.web_subnet_key]
  security_group_id   = module.network.web_security_group_id
  instance_type       = var.web_instance_type
  data_volume_size_gb = var.data_volume_size_gb
  initial_image_tag   = var.initial_image_tag
  ecr_repository_url  = aws_ecr_repository.app.repository_url
  ecr_repository_name = aws_ecr_repository.app.name

  db_app_secret_arn    = module.database.app_secret_arn
  db_master_secret_arn = module.database.master_secret_arn

  # Embedded in user_data: changing either file replaces the instance (user_data_replace_on_change).
  docker_compose_content = file("${path.root}/../app/docker-compose.yml")
  nginx_conf_content     = file("${path.root}/../app/nginx/nginx.conf")

  log_retention_days = var.log_retention_days
}

module "observability" {
  source = "../modules/observability"

  project            = var.project
  name_prefix        = local.name_prefix
  environment        = var.environment
  aws_region         = var.aws_region
  alerts_topic_name  = var.alerts_topic_name
  log_retention_days = var.log_retention_days
  office_hours       = var.office_hours
  health_check_rate  = var.health_check_rate

  instance_id              = module.web.instance_id
  instance_arn             = module.web.instance_arn
  public_ip                = module.web.public_ip
  db_identifier            = module.database.identifier
  db_arn                   = module.database.arn
  container_log_group_name = module.web.container_log_group_name
}
