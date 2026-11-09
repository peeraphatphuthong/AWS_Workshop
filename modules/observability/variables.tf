variable "project" {
  description = "Project name; IAM roles go under the /<project>/ path."
  type        = string
}

variable "name_prefix" {
  type = string
}

variable "environment" {
  description = "Used for the custom metric namespace RetailHealth/<environment>."
  type        = string
}

variable "aws_region" {
  type = string
}

variable "alerts_topic_name" {
  description = "Existing SNS topic for alarms (created by the bootstrap stack, which holds the email subscription)."
  type        = string
}

variable "instance_id" {
  type = string
}

variable "instance_arn" {
  type = string
}

variable "public_ip" {
  description = "Public IP the synthetic health check calls."
  type        = string
}

variable "db_identifier" {
  type = string
}

variable "db_arn" {
  type = string
}

variable "container_log_group_name" {
  description = "Log group with the nginx JSON access logs (for the 5xx metric filter and dashboard)."
  type        = string
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "office_hours" {
  description = <<-EOT
    Stop EC2 + RDS outside working hours with EventBridge Scheduler (cron in local time).
    Start RDS before EC2 (it takes ~5-10 min) and stop EC2 before RDS, so the app never runs
    without its database.
  EOT
  type = object({
    enabled   = bool
    timezone  = string
    start_db  = string
    start_web = string
    stop_web  = string
    stop_db   = string
  })
}

variable "health_check_rate" {
  description = "How often the synthetic health check calls /readyz."
  type        = string
  default     = "rate(5 minutes)"
}
