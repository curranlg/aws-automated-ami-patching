output "lambda_name" {
  value = aws_lambda_function.asg_ami_scheduler.function_name
}

output "scheduler_execution_role_arn" {
  value = aws_iam_role.scheduler_exec.arn
}