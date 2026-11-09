variable "project" {
  description = "Project name; IAM roles go under the /<project>/ path (the only path CI may manage)."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names, e.g. aws-workshop-dev."
  type        = string
}

variable "param_prefix" {
  description = "Parameter Store path prefix, e.g. /retail-health/dev (log group lives under it)."
  type        = string
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets for the tasks. Public subnets + public IP, because there is no NAT Gateway."
  type        = list(string)
}

# ---- shared with the EC2 web tier (same ALB, same database, same image) ----
variable "alb_arn" {
  description = "Existing ALB to add the comparison listener to (no second ALB = no extra ~$18/month)."
  type        = string
}

variable "alb_security_group_id" {
  type = string
}

variable "db_security_group_id" {
  type = string
}

variable "db_app_secret_arn" {
  description = "Secrets Manager secret with the app DB user (JSON: host, port, dbname, username, password)."
  type        = string
}

variable "ecr_repository_url" {
  type = string
}

variable "image_tag_parameter" {
  description = "SSM parameter holding the git SHA to run (owned by CI/CD, shared with the EC2 tier)."
  type        = string
}

# ---- task / service settings ----
variable "listener_port" {
  description = "ALB port that serves the Fargate version of the app."
  type        = number
  default     = 8080
}

variable "listener_cidr" {
  description = "Who may reach the comparison listener."
  type        = string
  default     = "0.0.0.0/0"
}

variable "container_port" {
  type    = number
  default = 3000
}

variable "cpu" {
  description = "Task CPU units (256 = 0.25 vCPU, the smallest Fargate size)."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Task memory in MiB (512 is the smallest allowed with 256 CPU)."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Tasks at creation and in the morning; afterwards owned by the schedules (ignore_changes)."
  type        = number
  default     = 1
}

variable "use_spot" {
  description = "Run on FARGATE_SPOT (~70% cheaper, can be interrupted with a 2-minute warning)."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  type    = number
  default = 7
}
