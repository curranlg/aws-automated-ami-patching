terraform {
  required_version = ">= 1.4.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
    }
  }
}

provider "aws" {
  region = "eu-west-2"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Package the Lambda
# ---------------------------------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = var.lambda_source_dir
  output_path = var.lambda_zip_path
}

# ---------------------------------------------------------------------------
# CloudWatch Logs for the Lambda
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.lambda_name}"
  retention_in_days = var.lambda_log_retention_days
}

# ---------------------------------------------------------------------------
# IAM ROLE: Lambda execution role
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${var.lambda_name}-Lambda-Role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  description        = "Execution role for ${var.lambda_name}"
}

# Inline policy for the Lambda to discover ASGs/EC2 and create/update schedules
data "aws_iam_policy_document" "lambda_policy" {
  statement {
    sid     = "DescribeASGAndEC2"
    effect  = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeImages"
    ]
    resources = ["*"]
  }

  # EventBridge Scheduler: create / update schedules
  # (Using Scheduler's API; not legacy EventBridge Rules)
  statement {
    sid     = "ManageScheduler"
    effect  = "Allow"
    actions = [
      "scheduler:CreateSchedule",
      "scheduler:UpdateSchedule",
      "scheduler:GetSchedule",
      "scheduler:DeleteSchedule",
      "scheduler:ListSchedules"
    ]
    resources = ["*"]
  }

  statement {
    sid     = "Logs"
    effect  = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }

  statement {
    sid     = "MiscRead"
    effect  = "Allow"
    actions = [
      "sts:GetCallerIdentity"
    ]
    resources = ["*"]
  }


  # allow Lambda to pass the Scheduler execution role to EventBridge Scheduler
  statement {
    sid     = "PassSchedulerExecutionRole"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [aws_iam_role.scheduler_exec.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["scheduler.amazonaws.com"]
    }
  }

}

resource "aws_iam_role_policy" "lambda_inline" {
  name   = "${var.lambda_name}-inline-policy"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.lambda_policy.json
}

# ---------------------------------------------------------------------------
# IAM ROLE: EventBridge Scheduler execution role (assumed by Scheduler)
# ---------------------------------------------------------------------------
# Trust policy must be scheduler.amazonaws.com
data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "scheduler_exec" {
  name               = var.eventbridge_scheduler_role_name
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
  description        = "Role assumed by EventBridge Scheduler to start SSM Automation runbooks"
}

# Permissions: StartAutomationExecution on both documents and automation-execution/*
# + allow pass of your AutomationAssumeRole to SSM
data "aws_iam_policy_document" "scheduler_permissions" {
  statement {
    sid     = "StartAutomation"
    effect  = "Allow"
    actions = ["ssm:StartAutomationExecution"]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:document/${var.windows_runbook}",
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:document/${var.linux_runbook}",
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:automation-execution/*"
    ]
  }

  statement {
    sid     = "PassAutomationAssumeRole"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [var.automation_assume_role_arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ssm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "scheduler_perm_inline" {
  name   = "${var.lambda_name}-scheduler-inline"
  role   = aws_iam_role.scheduler_exec.id
  policy = data.aws_iam_policy_document.scheduler_permissions.json
}

# ---------------------------------------------------------------------------
# Lambda function
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "asg_ami_scheduler" {
  function_name = var.lambda_name
  description   = "Discovers ASGs, detects OS, and creates EventBridge Scheduler schedules for SSM automation runbooks."
  role          = aws_iam_role.lambda_exec.arn
  handler       = "auto_schedule_ssm.lambda_handler"
  runtime       = "python3.12"
  filename      = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout       = var.lambda_timeout_sec
  memory_size   = var.lambda_memory_mb

  environment {
    variables = {
      WINDOWS_RUNBOOK             = var.windows_runbook
      LINUX_RUNBOOK               = var.linux_runbook
      IAM_INSTANCE_PROFILE_NAME   = var.iam_instance_profile_name
      AUTOMATION_ASSUME_ROLE_ARN  = var.automation_assume_role_arn
      INSTANCE_TYPE               = var.instance_type
      SUBNET_ID                   = var.subnet_id
      TRIGGER_INSTANCE_REFRESH    = var.trigger_instance_refresh
      SCHEDULER_EXECUTION_ROLE_ARN = aws_iam_role.scheduler_exec.arn
      SCHEDULE_PREFIX             = var.schedule_prefix
      SCHEDULE_HOUR_UTC           = tostring(var.schedule_hour_utc)
      TIMEZONE                    = var.schedule_timezone
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda
  ]
}

### Create a trigger to run Lambda when a new ASG is created
resource "aws_cloudwatch_event_rule" "asg_created" {
  name        = "invoke-ami-scheduler-on-asg-create"
  description = "Triggers Lambda when a new Auto Scaling Group is created"
  event_pattern = jsonencode({
    "source": ["aws.autoscaling"],
    "detail-type": ["AWS API Call via CloudTrail"],
    "detail": {
      "eventName": ["CreateAutoScalingGroup"]
    }
  })
}

resource "aws_cloudwatch_event_target" "asg_created_target" {
  rule      = aws_cloudwatch_event_rule.asg_created.name
  target_id = "asg-ami-scheduler-lambda"
  arn       = aws_lambda_function.asg_ami_scheduler.arn
}

# Allow EventBridge to invoke your Lambda
resource "aws_lambda_permission" "allow_eventbridge_invoke" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.asg_ami_scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.asg_created.arn
}

# ---------------------------------------------------------------------------
# EventBridge Rule (scheduled) to invoke the Lambda on a user-defined cadence
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "lambda_scheduled_trigger" {
  count              = var.lambda_scheduled_trigger_enabled ? 1 : 0
  name               = "${var.lambda_name}_scheduled-trigger"
  description        = var.lambda_trigger_description
  schedule_expression = var.lambda_trigger_schedule_expression
}

resource "aws_cloudwatch_event_target" "lambda_scheduled_trigger_target" {
  count     = var.lambda_scheduled_trigger_enabled ? 1 : 0
  rule      = aws_cloudwatch_event_rule.lambda_scheduled_trigger[0].name
  target_id = "invoke-${var.lambda_name}"
  arn       = aws_lambda_function.asg_ami_scheduler.arn
}

# Allow EventBridge to invoke the Lambda from the scheduled rule
resource "aws_lambda_permission" "allow_eventbridge_scheduled_invoke" {
  count         = var.lambda_scheduled_trigger_enabled ? 1 : 0
  statement_id  = "AllowExecutionFromEventBridgeSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.asg_ami_scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_scheduled_trigger[0].arn
}