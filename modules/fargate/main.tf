# ------------------------------------------------------------------------------------------
# Phase 8.4: the same container on ECS Fargate, side by side with the EC2 + ASG tier.
#
#   EC2 tier (modules/web)                     Fargate (this module)
#   ─────────────────────────────────────────  ─────────────────────────────────────────
#   launch template + user_data (bash, ~4 min) task definition (JSON, starts in ~1 min)
#   AL2023 + Docker + Compose on the host      no host: AWS runs and patches it
#   nginx sidecar -> app                       ALB -> app directly
#   deploy: SSM Run Command, script on host    deploy: new task definition revision
#   rollback: our pipeline script              rollback: deployment circuit breaker
#   ASG scales instances                       service scales tasks
#
# Same image (ECR, tag from the shared SSM parameter), same ALB (port 8080), same RDS database.
# ------------------------------------------------------------------------------------------

locals {
  container_name = "app"
}

# The git SHA CI/CD deployed last (same parameter the EC2 instances read at boot).
# insecure_value: the tag is not a secret, and a sensitive value would hide the image diff in plans.
data "aws_ssm_parameter" "image_tag" {
  name = var.image_tag_parameter
}

resource "aws_ecs_cluster" "main" {
  name = var.name_prefix

  # Container Insights adds per-task CPU/memory/network metrics, but they are billed as custom
  # metrics (several $/month even for one task). The free AWS/ECS service metrics are enough here.
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "${var.param_prefix}/fargate"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name_prefix}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc" # required on Fargate: each task gets its own ENI + security group
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64" # the image is built for amd64 by app-ci
  }

  # Ephemeral task storage (20 GiB free, gone when the task stops) for the app's scratch log.
  volume {
    name = "data"
  }

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = "${var.ecr_repository_url}:${data.aws_ssm_parameter.image_tag.insecure_value}"
      essential = true

      portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]

      # Same hardening as docker-compose.yml on EC2.
      readonlyRootFilesystem = true
      user                   = "node"
      mountPoints            = [{ sourceVolume = "data", containerPath = "/data", readOnly = false }]
      linuxParameters        = { initProcessEnabled = true } # reaps zombies, forwards SIGTERM

      environment = [
        { name = "DATA_DIR", value = "/data" },
        { name = "DB_SSL_CA", value = "/app/certs/rds-global-bundle.pem" },
        { name = "IMDS_DISABLED", value = "true" }, # no EC2 instance metadata on Fargate
      ]

      # The ECS agent reads single JSON keys of the secret and injects them as env vars at start.
      # Compare EC2: user_data/deploy-app calls `aws secretsmanager get-secret-value` + jq itself.
      secrets = [
        for env, key in {
          DB_HOST     = "host"
          DB_PORT     = "port"
          DB_NAME     = "dbname"
          DB_USER     = "username"
          DB_PASSWORD = "password"
        } : { name = env, valueFrom = "${var.db_app_secret_arn}:${key}::" }
      ]

      # Container health check (ECS replaces the task if it fails). The ALB checks /healthz too.
      healthCheck = {
        command     = ["CMD-SHELL", "wget -qO- http://127.0.0.1:${var.container_port}/healthz || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "app"
        }
      }
    }
  ])

  # CI/CD registers new revisions with a new image (and writes the same tag to the SSM parameter).
  # track_latest: compare against the LATEST revision instead of the one Terraform created, so a
  # deploy by the pipeline is not seen as drift.
  track_latest = true
}

resource "aws_ecs_service" "app" {
  name            = "${var.name_prefix}-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count

  capacity_provider_strategy {
    capacity_provider = var.use_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true # no NAT Gateway: needed to reach ECR / Secrets Manager / Logs
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  # Rolling deploy: start the new task, wait until healthy, then stop the old one.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 30

  # Built-in automatic rollback: if new tasks keep failing to become healthy, ECS stops the
  # deployment and goes back to the last working revision. (EC2 tier: our pipeline does this.)
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  propagate_tags = "SERVICE"

  lifecycle {
    # Owned by the office-hours schedules (0 at night) after creation.
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_lb_listener.app, # a target group must belong to a listener before a service can use it
    aws_ecs_cluster_capacity_providers.main,
    aws_iam_role_policy.execution_secrets,
    aws_vpc_security_group_ingress_rule.db_from_tasks,
  ]
}
