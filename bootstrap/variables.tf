variable "aws_region" {
  description = "Region for all resources. The sandbox account only allows ap-southeast-2."
  type        = string
  default     = "ap-southeast-2"
}

variable "project" {
  description = "Short project name used as a prefix for resource names."
  type        = string
  default     = "aws-workshop"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,20}$", var.project))
    error_message = "project must be 3-20 chars of lowercase letters, digits or hyphens."
  }
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose CI uses the credentials created here."
  type        = string
  default     = "peeraphatphuthong/AWS_Workshop"
}

variable "budget_limit_usd" {
  description = "Monthly cost budget in USD."
  type        = number
  default     = 10
}

variable "budget_alert_emails" {
  description = "Emails that receive budget alerts. Set in terraform.tfvars (git-ignored)."
  type        = list(string)

  validation {
    condition     = length(var.budget_alert_emails) > 0
    error_message = "Provide at least one email for budget alerts."
  }
}
