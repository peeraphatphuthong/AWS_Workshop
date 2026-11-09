# ------------------------------------------------------------------------------------------
# Web host: EC2 + Elastic IP + EBS data volume.
# ------------------------------------------------------------------------------------------

# Latest Amazon Linux 2023 AMI from the public SSM parameter AWS maintains
# (more reliable than an aws_ami name filter).
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  name_prefix  = var.name_prefix
  param_prefix = var.param_prefix

  # Fixed private IP: .50 inside the subnet (cidrhost avoids typing "10.20.1.50" by hand).
  web_private_ip = cidrhost(var.subnet.cidr, 50)

  # Parameter names starting with "aws" or "ssm" are RESERVED by SSM (AccessDenied
  # "No access to reserved parameter name"), so the prefix can't be "/aws-workshop/".
  image_tag_param_name = "${local.param_prefix}/app/image-tag"
  ecr_registry         = split("/", var.ecr_repository_url)[0]
}

# Desired app version lives in Parameter Store. Terraform creates it once; after that the
# CI/CD pipeline owns the value (ignore_changes) — infra code and app releases are decoupled.
resource "aws_ssm_parameter" "image_tag" {
  name        = local.image_tag_param_name
  description = "Git SHA of the retail-health image the web host should run"
  type        = "String"
  value       = var.initial_image_tag

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_instance" "web" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet.id
  private_ip             = local.web_private_ip
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.web.name

  # IMDSv2 only. Hop limit 2 so containers (one extra network hop) can still reach IMDS.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # T3 credit mode — a FinOps trade-off we got wrong first (Phase 7):
  #   "standard" looked cheaper, but T3 (unlike T2) gets NO launch credits. A new instance starts at
  #   0 credits and is throttled to the 10% baseline, so the first boot (dnf + docker pull/extract)
  #   took 10+ minutes instead of ~3, on every replacement.
  #   "unlimited" bursts as needed; surplus is billed at $0.05/vCPU-hour only if it isn't earned back.
  #   A boot burst costs cents. The real risk — sustained high CPU — is caught by the
  #   ec2-cpu-surplus-high alarm (CPUSurplusCreditBalance) instead of being silently throttled.
  credit_specification {
    cpu_credits = "unlimited"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region          = var.aws_region
    ecr_registry    = local.ecr_registry
    ecr_repository  = var.ecr_repository_name
    image_tag_param = local.image_tag_param_name
    # EBS volume ID lets the script find the right NVMe device (see note on aws_ebs_volume).
    data_volume_id         = aws_ebs_volume.app_data.id
    db_app_secret_arn      = var.db_app_secret_arn
    db_master_secret_arn   = var.db_master_secret_arn
    compose_version        = "v5.6.1"
    compose_sha256         = "47737f4236e6d3ccea7291995203f8f018058783b4c3a9469119811a0b5db8c0"
    docker_compose_content = var.docker_compose_content
    nginx_conf_content     = var.nginx_conf_content
    container_log_group    = aws_cloudwatch_log_group.containers.name
  })
  # Treat the host as immutable: a bootstrap change builds a fresh instance instead of
  # silently doing nothing (user_data only runs on first boot).
  user_data_replace_on_change = true

  lifecycle {
    # A new AMI is published every few weeks; don't replace the server on every plan because of it.
    # Patch on purpose with `terraform apply -replace=aws_instance.web`.
    ignore_changes = [ami]
  }

  tags = { Name = "${local.name_prefix}-web" }

  # Hidden dependencies: user_data calls SSM + ECR on first boot, so the role's policies must be
  # attached BEFORE the instance starts. Nothing in the instance block references those
  # attachments, so Terraform would happily create them in parallel (and `-target` would skip
  # them entirely). Found by running `terraform plan -target=aws_volume_attachment.app_data`.
  depends_on = [
    aws_ssm_parameter.image_tag,
    aws_iam_role_policy_attachment.web_ssm,
    aws_iam_role_policy_attachment.web_ecr,
    aws_iam_role_policy.web_params,
    aws_iam_role_policy.web_db_secrets,
    aws_iam_role_policy.web_logs, # Docker's awslogs driver must be allowed to write before containers start
    # The DB app secret must have a VALUE before first boot: var.db_app_secret_arn comes from a
    # database-module output that depends on the secret version, so that ordering is implicit.
  ]
}

# EBS volumes are ZONAL: they can only attach to an instance in the same AZ.
# The AZ is taken from the subnet the instance lives in (same source of truth as the instance).
# Note: using aws_instance.web.availability_zone here would create a dependency cycle, because
# the instance's user_data needs this volume's ID.
resource "aws_ebs_volume" "app_data" {
  availability_zone = var.subnet.az
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${local.name_prefix}-app-data" }
}

resource "aws_volume_attachment" "app_data" {
  device_name = "/dev/sdf" # shows up as /dev/nvme1n1 on Nitro instances (t3)
  volume_id   = aws_ebs_volume.app_data.id
  instance_id = aws_instance.web.id

  # Stop the instance before detaching so the filesystem isn't yanked while mounted.
  stop_instance_before_detaching = true
}

resource "aws_eip" "web" {
  domain                    = "vpc"
  instance                  = aws_instance.web.id
  associate_with_private_ip = local.web_private_ip

  # An EIP in a VPC needs the Internet Gateway attached first. Inside one stack this was an
  # explicit depends_on; across modules the network module's public_subnets output depends on
  # the IGW + default route, and the instance (-> this EIP) uses that subnet.

  tags = { Name = "${local.name_prefix}-web-eip" }
}
