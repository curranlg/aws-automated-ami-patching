variable "automation_role_name" {
  type        = string
  description = "Name for the SSM Automation assume role."
  default     = "SSMAutomation"
}

variable "instance_profile_role_arn" {
  type        = string
  description = <<-EOT
    ARN of the EC2 Instance Profile ROLE that your runbook attaches to the temporary builder instance.
    Required if your runbook calls ec2:RunInstances with IamInstanceProfile.Name/Arn.
    This role will be allowed via iam:PassRole -> ec2.amazonaws.com.
  EOT
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