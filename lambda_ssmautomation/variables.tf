variable "lambda_name" {
  type        = string
  description = "Name of the Lambda function."
  default     = "ASG-AMIUpdate-Scheduler"
}

variable "windows_runbook" {
  type        = string
  description = "SSM Automation runbook for Windows."
  default     = "Custom-Update-Windows-AMI-With-LT"
}

variable "linux_runbook" {
  type        = string
  description = "SSM Automation runbook for Linux."
  default     = "Custom-Update-Linux-AMI-With-LT"
}

variable "eventbridge_scheduler_role_name" {
  type        = string
  description = "Name of the Eventbridge Scheduler IAM Role"
  default     = "Eventbridge-to-SSM-Automation-Role"
}

variable "iam_instance_profile_name" {
  type        = string
  description = "Name of the IAM Instance Profile used by the AMI builder instance."
}

variable "automation_assume_role_arn" {
  type        = string
  description = "ARN of the role that SSM Automation should assume (AutomationAssumeRole)."
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for AMI build steps."
  default     = "t3.medium"
}

variable "subnet_id" {
  type        = string
  description = "Optional SubnetId for the temporary builder instance. Leave empty to omit."
  default     = ""
}

variable "trigger_instance_refresh" {
  type        = string
  description = "Whether the runbook should trigger an ASG instance refresh (string 'true' or 'false')."
  default     = "false"
}

variable "schedule_prefix" {
  type        = string
  description = "Prefix for EventBridge Scheduler schedules created per ASG."
  default     = "UpdateAMIForASG_"
}

variable "schedule_hour_utc" {
  type        = number
  description = "Hour (0..23) UTC that each schedule will run."
  default     = 3
  validation {
    condition     = var.schedule_hour_utc >= 0 && var.schedule_hour_utc <= 23
    error_message = "schedule_hour_utc must be 0..23."
  }
}

variable "schedule_timezone" {
  type        = string
  description = "Optional IANA timezone (e.g. Europe/London). Empty = UTC."
  default     = ""
}

variable "lambda_memory_mb" {
  type        = number
  description = "Lambda memory (MB)."
  default     = 256
}

variable "lambda_timeout_sec" {
  type        = number
  description = "Lambda timeout (seconds)."
  default     = 60
}

variable "lambda_log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention in days."
  default     = 30
}

variable "lambda_zip_path" {
  type        = string
  description = "Where to write the zipped Lambda package."
  default     = "dist/asg-ami-scheduler.zip"
}

variable "lambda_source_dir" {
  type        = string
  description = "Directory containing the Lambda source."
  default     = "lambda"
}



# Toggle the scheduled trigger for the Lambda
variable "lambda_scheduled_trigger_enabled" {
  type        = bool
  description = "Enable/disable the scheduled EventBridge Rule that invokes the Lambda."
  default     = true
}

# The schedule expression for EventBridge Rule that invokes the Lambda
# Accepts cron(...) or rate(...).
# Examples:
#   - Nightly at 01:00 UTC:           cron(0 1 * * ? *)
#   - First day of month at 03:00:    cron(0 3 1 * ? *)
#   - Every 12 hours:                 rate(12 hours)
variable "lambda_trigger_schedule_expression" {
  type        = string
  description = "EventBridge Rule schedule expression to run the Lambda (cron(...) or rate(...))."
  default     = "cron(0 1 * * ? *)" # nightly 01:00 UTC by default
}

# Optional description for the scheduled rule
variable "lambda_trigger_description" {
  type        = string
  description = "Optional description for the scheduled EventBridge Rule."
  default     = "Periodically runs ASG AMI Scheduler Lambda to sync schedules for any ASG changes"
}