# ------------------------------------------------------------------------------------------
# Web tier (Phase 8.3): Application Load Balancer -> Auto Scaling Group of stateless instances.
#
#   Internet ──► ALB (public subnets, 2 AZs) ──► target group ──► ASG instances (launch template)
#
# Before 8.3 this was ONE instance with an Elastic IP and an EBS data volume. Instances are now
# cattle, not pets: any of them can be replaced at any time, so nothing durable lives on them
# (durable data is in RDS; the app's local "health log" is per-instance scratch on the root disk).
# ------------------------------------------------------------------------------------------

# Latest Amazon Linux 2023 AMI from the public SSM parameter AWS maintains.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  name_prefix  = var.name_prefix
  param_prefix = var.param_prefix

  # Parameter names starting with "aws" or "ssm" are RESERVED by SSM (AccessDenied
  # "No access to reserved parameter name"), so the prefix can't be "/aws-workshop/".
  image_tag_param_name = "${local.param_prefix}/app/image-tag"
  ecr_registry         = split("/", var.ecr_repository_url)[0]
}

# Desired app version lives in Parameter Store. Terraform creates it once; after that the
# CI/CD pipeline owns the value (ignore_changes). New ASG instances read it at boot, so a
# scale-out always runs the current release.
resource "aws_ssm_parameter" "image_tag" {
  name        = local.image_tag_param_name
  description = "Git SHA of the retail-health image the web host should run"
  type        = "String"
  value       = var.initial_image_tag

  lifecycle {
    ignore_changes = [value]
  }
}

# ---------------------------------------------------------------- launch template
resource "aws_launch_template" "web" {
  name_prefix            = "${local.name_prefix}-web-"
  description            = "retail-health web host (Amazon Linux 2023 + Docker Compose)"
  image_id               = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  update_default_version = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.web.arn
  }

  # Public IP: without a NAT Gateway (~$45/month) the instances need one to reach ECR, SSM and
  # package mirrors. Inbound is still closed: the web SG only accepts the ALB's SG.
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [var.security_group_id]
    delete_on_termination       = true
  }

  # IMDSv2 only. Hop limit 2 so containers (one extra network hop) can still reach IMDS.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # T3 has NO launch credits: "standard" throttled the first boot to 10% CPU (Phase 7 incident).
  # Every ASG launch is a first boot, so "unlimited" matters even more here.
  credit_specification {
    cpu_credits = "unlimited"
  }

  block_device_mappings {
    device_name = "/dev/xvda" # AL2023 root device
    ebs {
      volume_type           = "gp3"
      volume_size           = 8
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region                 = var.aws_region
    ecr_registry           = local.ecr_registry
    ecr_repository         = var.ecr_repository_name
    image_tag_param        = local.image_tag_param_name
    db_app_secret_arn      = var.db_app_secret_arn
    db_master_secret_arn   = var.db_master_secret_arn
    compose_version        = "v5.6.1"
    compose_sha256         = "47737f4236e6d3ccea7291995203f8f018058783b4c3a9469119811a0b5db8c0"
    docker_compose_content = var.docker_compose_content
    nginx_conf_content     = var.nginx_conf_content
    container_log_group    = aws_cloudwatch_log_group.containers.name
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name_prefix}-web" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${local.name_prefix}-web-root" }
  }

  # Hidden dependencies: user_data calls SSM, ECR, Secrets Manager and CloudWatch Logs on first
  # boot, so the role's policies must exist before any instance is launched from this template.
  depends_on = [
    aws_ssm_parameter.image_tag,
    aws_iam_role_policy_attachment.web_ssm,
    aws_iam_role_policy_attachment.web_ecr,
    aws_iam_role_policy.web_params,
    aws_iam_role_policy.web_db_secrets,
    aws_iam_role_policy.web_logs,
  ]
}

# ---------------------------------------------------------------- load balancer
resource "aws_lb" "web" {
  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = [for s in var.subnets : s.id]
  security_groups    = [var.alb_security_group_id]

  # Reject requests with malformed headers instead of passing them to the app (request smuggling).
  drop_invalid_header_fields = true

  tags = { Name = "${local.name_prefix}-alb" }
}

resource "aws_lb_target_group" "web" {
  name     = "${local.name_prefix}-web"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  # Liveness, NOT readiness. If the ALB checked /readyz, a database outage would mark EVERY
  # instance unhealthy, the ASG (health_check_type = ELB) would terminate them all and keep
  # replacing them — turning a DB problem into a full outage plus a launch storm.
  # Readiness (/readyz, includes the DB) is watched by the synthetic health check + alarm instead.
  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Seconds the ALB keeps sending in-flight requests to a target being removed (default 300).
  deregistration_delay = 30

  tags = { Name = "${local.name_prefix}-web-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP" # HTTPS needs an ACM certificate for a domain we own (not in this sandbox)

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# ---------------------------------------------------------------- auto scaling group
resource "aws_autoscaling_group" "web" {
  name                = "${local.name_prefix}-web"
  vpc_zone_identifier = [for s in var.subnets : s.id] # spread across AZs
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.min_size
  target_group_arns   = [aws_lb_target_group.web.arn]

  # Replace instances that fail the ALB health check, not only the EC2 status checks.
  health_check_type = "ELB"
  # Boot = dnf + docker pull + db-bootstrap + deploy (~3-4 min). Don't judge health before that.
  health_check_grace_period = 420
  default_instance_warmup   = 120
  wait_for_capacity_timeout = "15m"

  launch_template {
    id      = aws_launch_template.web.id
    version = aws_launch_template.web.latest_version
  }

  # Zero-downtime infrastructure changes: a new launch template version (new AMI, user_data,
  # instance type) starts a rolling refresh. min 100% / max 200% = launch the new instance, wait
  # until it is healthy behind the ALB, THEN terminate the old one ("launch before terminate").
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
    }
  }

  # Group metrics (instances in service etc.) for the dashboard; ASG group metrics are free.
  enabled_metrics = ["GroupDesiredCapacity", "GroupInServiceInstances", "GroupTotalInstances"]

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-web"
    propagate_at_launch = true
  }

  lifecycle {
    # desired_capacity is owned by scaling policies and the office-hours scheduled actions;
    # min_size by the scheduled actions (0 at night). Terraform sets them only at creation.
    ignore_changes = [desired_capacity, min_size]
  }
}

# Scale on load: keep average CPU around the target by adding/removing instances (min..max).
resource "aws_autoscaling_policy" "cpu" {
  name                   = "cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.web.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target_percent
  }
}
