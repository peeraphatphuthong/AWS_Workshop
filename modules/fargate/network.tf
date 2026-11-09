# ------------------------------------------------------------------------------------------
# Networking for the Fargate comparison: its own security group, wired to the SAME ALB and the
# SAME database as the EC2 tier. All rules that touch other modules' security groups live here,
# so deleting this module removes every trace of it (nothing to clean up in modules/network).
#
#   Internet ─:80──► ALB ──► EC2 target group (instances, port 80 nginx)      [modules/web]
#   Internet ─:8080► ALB ──► Fargate target group (task IPs, port 3000 app)   [this module]
#                                     └──────────────► RDS :3306 (both tiers)
# ------------------------------------------------------------------------------------------

resource "aws_security_group" "tasks" {
  name_prefix = "${var.name_prefix}-fargate-"
  description = "Fargate tasks: app port from the ALB only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-fargate-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "App port from the load balancer only"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = var.alb_security_group_id
}

# HTTPS only (ECR image pull, Secrets Manager, CloudWatch Logs). Unlike the EC2 host there is no
# OS to patch, so no port 80 to package mirrors.
resource "aws_vpc_security_group_egress_rule" "tasks_https_out" {
  security_group_id = aws_security_group.tasks.id
  description       = "HTTPS to AWS APIs (ECR, Secrets Manager, Logs)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "tasks_to_db" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "MySQL to the database tier"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = var.db_security_group_id
}

# ---- rules added to security groups owned by modules/network ----
resource "aws_vpc_security_group_ingress_rule" "db_from_tasks" {
  security_group_id            = var.db_security_group_id
  description                  = "MySQL from Fargate tasks"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.tasks.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_listener" {
  security_group_id = var.alb_security_group_id
  description       = "Fargate comparison listener"
  ip_protocol       = "tcp"
  from_port         = var.listener_port
  to_port           = var.listener_port
  cidr_ipv4         = var.listener_cidr
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = var.alb_security_group_id
  description                  = "App port to the Fargate tasks"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.tasks.id
}

# ---- load balancer: second listener + target group on the existing ALB ----
resource "aws_lb_target_group" "app" {
  name        = "${var.name_prefix}-app"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # awsvpc networking: every task has its own ENI/IP, registered by ECS

  # Same reasoning as the EC2 target group: liveness, not readiness (see modules/web/compute.tf).
  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = { Name = "${var.name_prefix}-app-tg" }
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = var.alb_arn
  port              = var.listener_port
  protocol          = "HTTP" # same limitation as port 80: no domain -> no ACM certificate

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
