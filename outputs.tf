output "ssm_automation_role_arn" {
  description = "ARN of the role SSM Automation runbooks assume."
  value       = aws_iam_role.ssm_automation_role.arn
}

output "windows_runbook_name" {
  description = "Name of the Windows SSM Automation document."
  value       = aws_ssm_document.update_windows_ami_with_lt.name
}

output "linux_runbook_name" {
  description = "Name of the Linux SSM Automation document."
  value       = aws_ssm_document.update_linux_ami_with_lt.name
}

output "lambda_name" {
  description = "Name of the ASG AMI scheduler Lambda function."
  value       = aws_lambda_function.asg_ami_scheduler.function_name
}

output "scheduler_execution_role_arn" {
  description = "ARN of the role EventBridge Scheduler assumes to start SSM Automation."
  value       = aws_iam_role.scheduler_exec.arn
}
