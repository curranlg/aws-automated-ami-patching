variable "aws_region" {
  type        = string
  description = "AWS region to deploy into."
  default     = "eu-west-2"
}

# ------------------------------------------------------------------------------
# Shared / cross-cutting
# ------------------------------------------------------------------------------

variable "ec2_instance_profile_name" {
  type        = string
  description = <<-EOT
    Name of the EC2 Instance Profile that gets attached to both:
      - your real ASG instances, and
      - the temporary AMI-builder instance the SSM runbook launches.
    The instance profile's underlying role ARN is looked up automatically
    (via aws_iam_instance_profile) and used for the required iam:PassRole grant,
    so you no longer need to supply the role ARN separately.
  EOT
}

# ------------------------------------------------------------------------------
# Part 1 — SSM Automation runbooks + role
# ------------------------------------------------------------------------------

variable "automation_role_name" {
  type        = string
  description = "Name for the SSM Automation assume role."
  default     = "SSMAutomation"
}

variable "allow_asg_instance_refresh" {
  type        = bool
  description = "Allow the automation role to start an Auto Scaling Group Instance Refresh."
  default     = true
}

variable "windows_runbook_path" {
  type        = string
  description = "Path to the Windows runbook JSON."
  default     = "./runbooks/My-UpdateWindowsAMI-NoSysPrep-LTUpdate_v4.json"
}

variable "linux_runbook_path" {
  type        = string
  description = "Path to the Linux runbook JSON."
  default     = "./runbooks/My-UpdateLinuxAMI-LTUpdate_v4.json"
}

variable "document_target_account_ids" {
  type        = list(string)
  description = "Accounts that can use the documents (set to your own account or list of accounts)."
  default     = []
}

# ------------------------------------------------------------------------------
# Part 2 — Lambda scheduler + EventBridge
# ------------------------------------------------------------------------------

variable "lambda_name" {
  type        = string
  description = "Name of the Lambda function."
  default     = "ASG-AMIUpdate-Scheduler"
}

variable "eventbridge_scheduler_role_name" {
  type        = string
  description = "Name of the Eventbridge Scheduler IAM Role"
  default     = "Eventbridge-to-SSM-Automation-Role"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for AMI build steps."
  default     = "t3.medium"
}

variable "subnet_id" {
  type        = string
  description = <<-EOT
    Optional manual override for the SubnetId used by the temporary
    AMI-builder instance. Leave blank (default) to have the Lambda
    auto-detect it per-ASG, from wherever that ASG's instances are actually
    running (falling back to the ASG's configured subnets if it's scaled to
    zero). Only set this if you need the builder instance placed somewhere
    different from the ASG's own subnets.
  EOT
  default     = ""
}

variable "security_group_ids" {
  type        = list(string)
  description = <<-EOT
    Optional manual override for the security groups attached to the
    temporary AMI-builder instance. Leave empty (default) to have the Lambda
    auto-detect them per-ASG, the same way subnet_id is auto-detected.
  EOT
  default     = []
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
