# ------------------------------------------------------------------------------------------
# Web host: EC2 + Elastic IP + EBS data volume.
# ------------------------------------------------------------------------------------------

# Latest Amazon Linux 2023 AMI from the public SSM parameter AWS maintains
# (more reliable than an aws_ami name filter).
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  web_subnet_key = "public-${substr(local.azs[0], -1, 1)}" # "public-a"
  web_subnet     = aws_subnet.this[local.web_subnet_key]

  # Fixed private IP: .50 inside the subnet (cidrhost avoids typing "10.20.1.50" by hand).
  web_private_ip = cidrhost(local.public_subnets[local.web_subnet_key].cidr, 50)

  # Parameter names starting with "aws" or "ssm" are RESERVED by SSM (AccessDenied
  # "No access to reserved parameter name"), so the prefix can't be "/aws-workshop/".
  image_tag_param_name = "${local.param_prefix}/app/image-tag"
  ecr_registry         = split("/", aws_ecr_repository.app.repository_url)[0]
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
  instance_type          = var.web_instance_type
  subnet_id              = local.web_subnet.id
  private_ip             = local.web_private_ip
  vpc_security_group_ids = [aws_security_group.web.id]
  iam_instance_profile   = aws_iam_instance_profile.web.name

  # IMDSv2 only. Hop limit 2 so containers (one extra network hop) can still reach IMDS.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
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
    ecr_repository  = aws_ecr_repository.app.name
    image_tag_param = local.image_tag_param_name
    # EBS volume ID lets the script find the right NVMe device (see note on aws_ebs_volume).
    data_volume_id         = aws_ebs_volume.app_data.id
    db_app_secret_arn      = aws_secretsmanager_secret.db_app.arn
    db_master_secret_arn   = aws_db_instance.mysql.master_user_secret[0].secret_arn
    compose_version        = "v5.6.1"
    compose_sha256         = "47737f4236e6d3ccea7291995203f8f018058783b4c3a9469119811a0b5db8c0"
    docker_compose_content = file("${path.module}/../app/docker-compose.yml")
    nginx_conf_content     = file("${path.module}/../app/nginx/nginx.conf")
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
    aws_secretsmanager_secret_version.db_app, # secret must have a value before first boot
  ]
}

# EBS volumes are ZONAL: they can only attach to an instance in the same AZ.
# The AZ is taken from the subnet the instance lives in (same source of truth as the instance).
# Note: using aws_instance.web.availability_zone here would create a dependency cycle, because
# the instance's user_data needs this volume's ID.
resource "aws_ebs_volume" "app_data" {
  availability_zone = local.web_subnet.availability_zone
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

  # An EIP in a VPC needs the Internet Gateway attached first. Terraform can't infer this
  # (no attribute reference), so the dependency is declared explicitly.
  depends_on = [aws_internet_gateway.main]

  tags = { Name = "${local.name_prefix}-web-eip" }
}
