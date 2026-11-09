# ------------------------------------------------------------------------------------------
# Phase 8: resources moved from the flat root into modules.
#
# Without these blocks Terraform would see "aws_vpc.main" disappear and "module.network.aws_vpc.main"
# appear, and plan to DESTROY and RECREATE everything (VPC, EC2, RDS = data loss + downtime).
# A `moved` block renames the address in state instead: the plan shows only "has moved to".
#
# for_each resources (aws_subnet.this, alarms, ...) move as a whole, all keys at once.
# Keep these blocks for a while (anyone with an old state/branch still needs them), then delete.
# ------------------------------------------------------------------------------------------

# ---- module.network

moved {
  from = aws_vpc.main
  to   = module.network.aws_vpc.main
}

moved {
  from = aws_internet_gateway.main
  to   = module.network.aws_internet_gateway.main
}

moved {
  from = aws_subnet.this
  to   = module.network.aws_subnet.this
}

moved {
  from = aws_route_table.public
  to   = module.network.aws_route_table.public
}

moved {
  from = aws_route.public_internet
  to   = module.network.aws_route.public_internet
}

moved {
  from = aws_route_table_association.public
  to   = module.network.aws_route_table_association.public
}

moved {
  from = aws_route_table.private
  to   = module.network.aws_route_table.private
}

moved {
  from = aws_route_table_association.private
  to   = module.network.aws_route_table_association.private
}

moved {
  from = aws_default_route_table.main
  to   = module.network.aws_default_route_table.main
}

moved {
  from = aws_default_security_group.default
  to   = module.network.aws_default_security_group.default
}

moved {
  from = aws_security_group.web
  to   = module.network.aws_security_group.web
}

moved {
  from = aws_vpc_security_group_ingress_rule.web
  to   = module.network.aws_vpc_security_group_ingress_rule.web
}

moved {
  from = aws_vpc_security_group_egress_rule.web_https_out
  to   = module.network.aws_vpc_security_group_egress_rule.web_https_out
}

moved {
  from = aws_vpc_security_group_egress_rule.web_http_out
  to   = module.network.aws_vpc_security_group_egress_rule.web_http_out
}

moved {
  from = aws_vpc_security_group_egress_rule.web_to_db
  to   = module.network.aws_vpc_security_group_egress_rule.web_to_db
}

moved {
  from = aws_security_group.db
  to   = module.network.aws_security_group.db
}

moved {
  from = aws_vpc_security_group_ingress_rule.db_from_web
  to   = module.network.aws_vpc_security_group_ingress_rule.db_from_web
}


# ---- module.database

moved {
  from = aws_db_subnet_group.main
  to   = module.database.aws_db_subnet_group.main
}

moved {
  from = aws_db_parameter_group.mysql
  to   = module.database.aws_db_parameter_group.mysql
}

moved {
  from = aws_db_instance.mysql
  to   = module.database.aws_db_instance.mysql
}

moved {
  from = aws_secretsmanager_secret.db_app
  to   = module.database.aws_secretsmanager_secret.db_app
}

moved {
  from = aws_secretsmanager_secret_version.db_app
  to   = module.database.aws_secretsmanager_secret_version.db_app
}

moved {
  from = aws_cloudwatch_log_group.rds
  to   = module.database.aws_cloudwatch_log_group.rds
}


# ---- module.web

moved {
  from = aws_ssm_parameter.image_tag
  to   = module.web.aws_ssm_parameter.image_tag
}

moved {
  from = aws_instance.web
  to   = module.web.aws_instance.web
}

moved {
  from = aws_ebs_volume.app_data
  to   = module.web.aws_ebs_volume.app_data
}

moved {
  from = aws_volume_attachment.app_data
  to   = module.web.aws_volume_attachment.app_data
}

moved {
  from = aws_eip.web
  to   = module.web.aws_eip.web
}

moved {
  from = aws_iam_role.web
  to   = module.web.aws_iam_role.web
}

moved {
  from = aws_iam_role_policy_attachment.web_ssm
  to   = module.web.aws_iam_role_policy_attachment.web_ssm
}

moved {
  from = aws_iam_role_policy_attachment.web_ecr
  to   = module.web.aws_iam_role_policy_attachment.web_ecr
}

moved {
  from = aws_iam_role_policy.web_db_secrets
  to   = module.web.aws_iam_role_policy.web_db_secrets
}

moved {
  from = aws_iam_role_policy.web_params
  to   = module.web.aws_iam_role_policy.web_params
}

moved {
  from = aws_iam_role_policy.web_logs
  to   = module.web.aws_iam_role_policy.web_logs
}

moved {
  from = aws_iam_instance_profile.web
  to   = module.web.aws_iam_instance_profile.web
}

moved {
  from = aws_cloudwatch_log_group.containers
  to   = module.web.aws_cloudwatch_log_group.containers
}


# ---- module.observability

moved {
  from = aws_cloudwatch_metric_alarm.this
  to   = module.observability.aws_cloudwatch_metric_alarm.this
}

moved {
  from = aws_cloudwatch_metric_alarm.ec2_auto_recover
  to   = module.observability.aws_cloudwatch_metric_alarm.ec2_auto_recover
}

moved {
  from = aws_cloudwatch_dashboard.main
  to   = module.observability.aws_cloudwatch_dashboard.main
}

moved {
  from = aws_cloudwatch_log_group.healthcheck
  to   = module.observability.aws_cloudwatch_log_group.healthcheck
}

moved {
  from = aws_iam_role.healthcheck
  to   = module.observability.aws_iam_role.healthcheck
}

moved {
  from = aws_iam_role_policy.healthcheck
  to   = module.observability.aws_iam_role_policy.healthcheck
}

moved {
  from = aws_lambda_function.healthcheck
  to   = module.observability.aws_lambda_function.healthcheck
}

moved {
  from = aws_scheduler_schedule_group.main
  to   = module.observability.aws_scheduler_schedule_group.main
}

moved {
  from = aws_iam_role.scheduler
  to   = module.observability.aws_iam_role.scheduler
}

moved {
  from = aws_iam_role_policy.scheduler
  to   = module.observability.aws_iam_role_policy.scheduler
}

moved {
  from = aws_scheduler_schedule.office_hours
  to   = module.observability.aws_scheduler_schedule.office_hours
}

moved {
  from = aws_scheduler_schedule.healthcheck
  to   = module.observability.aws_scheduler_schedule.healthcheck
}

moved {
  from = aws_cloudwatch_log_metric_filter.nginx_5xx
  to   = module.observability.aws_cloudwatch_log_metric_filter.nginx_5xx
}
