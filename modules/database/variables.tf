variable "name_prefix" {
  description = "Prefix for resource names, e.g. aws-workshop-dev."
  type        = string
}

variable "param_prefix" {
  description = "Secrets Manager / Parameter Store path prefix, e.g. /retail-health/dev."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the DB subnet group (>= 2 AZs)."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group of the database tier."
  type        = string
}

variable "instance_class" {
  description = "RDS instance class. db.t4g.micro (Graviton) is the cheapest option for MySQL 8.4."
  type        = string
  default     = "db.t4g.micro"
}

variable "app_password_version" {
  description = "Increment to generate and store a new application DB password (rotation)."
  type        = number
  default     = 1
}

variable "log_retention_days" {
  description = "Retention of the RDS log groups."
  type        = number
  default     = 7
}
