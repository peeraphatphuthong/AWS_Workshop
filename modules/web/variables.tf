variable "project" {
  description = "Project name; IAM entities go under the /<project>/ path (the only path CI may manage)."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names, e.g. aws-workshop-dev."
  type        = string
}

variable "param_prefix" {
  description = "Parameter Store / Secrets Manager path prefix, e.g. /retail-health/dev."
  type        = string
}

variable "aws_region" {
  type = string
}

variable "subnet" {
  description = "Public subnet for the host: { id, az, cidr }. The EBS volume is created in the same AZ."
  type = object({
    id   = string
    az   = string
    cidr = string
  })
}

variable "security_group_id" {
  type = string
}

variable "instance_type" {
  description = "EC2 instance type for the web host."
  type        = string
  default     = "t3.micro"
}

variable "data_volume_size_gb" {
  description = "Size of the EBS data volume mounted at /mnt/app-data."
  type        = number
  default     = 10
}

variable "initial_image_tag" {
  description = "Image tag (git SHA) written to Parameter Store on first apply. CI/CD updates it afterwards."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.initial_image_tag))
    error_message = "initial_image_tag must be a full 40-character git SHA."
  }
}

variable "ecr_repository_url" {
  type = string
}

variable "ecr_repository_name" {
  type = string
}

variable "db_app_secret_arn" {
  description = "Secret with the application DB user (must already have a value)."
  type        = string
}

variable "db_master_secret_arn" {
  description = "RDS-managed master secret (used only by db-bootstrap on the host)."
  type        = string
}

variable "docker_compose_content" {
  description = "docker-compose.yml written to the host by user_data."
  type        = string
}

variable "nginx_conf_content" {
  description = "nginx.conf written to the host by user_data."
  type        = string
}

variable "log_retention_days" {
  type    = number
  default = 7
}
