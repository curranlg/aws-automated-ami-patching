output "ssm_automation_role_arn" {
  value = aws_iam_role.ssm_automation_role.arn
}

output "windows_runbook_name" {
  value = aws_ssm_document.update_windows_ami_with_lt.name
}

output "linux_runbook_name" {
  value = aws_ssm_document.update_linux_ami_with_lt.name
}