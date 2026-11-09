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

# ---- production knobs (defaults = lab/dev settings) ----
variable "multi_az" {
  description = "Synchronous standby in a second AZ with automatic failover (~2x price)."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Automated backup / point-in-time-restore window."
  type        = number
  default     = 1
}

variable "deletion_protection" {
  description = "Block DeleteDBInstance (also blocks terraform destroy until turned off)."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Delete without a final snapshot. Must be false where data matters."
  type        = bool
  default     = true
}

variable "apply_immediately" {
  description = "Apply modifications now instead of in the next maintenance window."
  type        = bool
  default     = true
}
