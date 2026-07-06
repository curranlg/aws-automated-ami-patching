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
  region = var.aws_region
  profile = "aws2025-liam"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ------------------------------------------------------------------------------
# Look up the EC2 instance profile once, so the caller only has to supply its
# NAME. We derive the role ARN (needed for iam:PassRole) from it, instead of
# asking for the name and the ARN as two separate, easy-to-mismatch inputs.
# ------------------------------------------------------------------------------
data "aws_iam_instance_profile" "ec2_builder_profile" {
  name = var.ec2_instance_profile_name
}


# ==============================================================================
# PART 1 — SSM AUTOMATION RUNBOOKS + AUTOMATION ROLE
# (Previously: custom_update_ami module)
# ==============================================================================

# ------------------------------------------------------------------------------
# SSM AUTOMATION "ASSUME ROLE" (used by the runbooks at execution time)
# Trusts ssm.amazonaws.com (Automation service) so the runbook can assume it.
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "automation_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]

    # Only allow assumptions from SSM Automations in THIS account
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    # And only from SSM Automation EXECUTION ARNs in this account/partition
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:automation-execution/*"
      ]
    }
  }
}

resource "aws_iam_role" "ssm_automation_role" {
  name               = var.automation_role_name
  assume_role_policy = data.aws_iam_policy_document.automation_trust.json
  description        = "Assume role for SSM Automation runbooks (AMI update & LT refresh)"
}

# -----------------------
# Permissions policy
# -----------------------
# The set below covers a typical AMI update + LT version + optional ASG Instance Refresh.
# Tweak further if your runbooks do more/less.

data "aws_iam_policy_document" "automation_permissions" {
  # Describe inventory needed by steps
  statement {
    sid    = "EC2Read"
    effect = "Allow"
    actions = [
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeLaunchTemplateVersions"
    ]
    resources = ["*"]
  }

  # Create/Tag AMI, launch/terminate builder instances, create/update LT
  statement {
    sid    = "EC2WriteCore"
    effect = "Allow"
    actions = [
      "ec2:CreateImage",
      "ec2:CreateTags",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:CreateLaunchTemplateVersion",
      "ec2:ModifyLaunchTemplate"
    ]
    resources = ["*"]
  }

  # Allow the Automation role to PASS the EC2 instance profile ROLE to EC2 when calling RunInstances
  # (Required when the runbook associates an instance profile to the builder instance).
  statement {
    sid       = "PassInstanceProfileRoleToEC2"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [data.aws_iam_instance_profile.ec2_builder_profile.role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # (Optional) Start Instance Refresh on the target ASG after LT is updated
  dynamic "statement" {
    for_each = var.allow_asg_instance_refresh ? [1] : []
    content {
      sid    = "ASGInstanceRefresh"
      effect = "Allow"
      actions = [
        "autoscaling:StartInstanceRefresh",
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeInstanceRefreshes"
      ]
      resources = ["*"]
    }
  }
}

resource "aws_iam_policy" "automation_policy" {
  name        = "${var.automation_role_name}-policy"
  description = "Permissions for SSM Automation runbooks to build AMIs and update Launch Templates"
  policy      = data.aws_iam_policy_document.automation_permissions.json
}

resource "aws_iam_role_policy_attachment" "attach_automation_policy" {
  role       = aws_iam_role.ssm_automation_role.name
  policy_arn = aws_iam_policy.automation_policy.arn
}

# ---------- attach the AWS managed policy ----------
data "aws_iam_policy" "amazon_ssm_automation_role" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonSSMAutomationRole"
}

resource "aws_iam_role_policy_attachment" "attach_managed_ssm_automation_role" {
  role       = aws_iam_role.ssm_automation_role.name
  policy_arn = data.aws_iam_policy.amazon_ssm_automation_role.arn
}

# ------------------------------------------------------------------------------
# SSM DOCUMENTS (Automation runbooks)
# ------------------------------------------------------------------------------

# WINDOWS
resource "aws_ssm_document" "update_windows_ami_with_lt" {
  name            = "Custom-Update-Windows-AMI-With-LT"
  document_type   = "Automation"
  document_format = "JSON"

  # Load your existing Windows runbook JSON
  content = file(var.windows_runbook_path)

  # Share with specific accounts if needed (optional)
  permissions = length(var.document_target_account_ids) > 0 ? {
    type        = "Share"
    account_ids = join(",", var.document_target_account_ids)
  } : null
}

# LINUX
resource "aws_ssm_document" "update_linux_ami_with_lt" {
  name            = "Custom-Update-Linux-AMI-With-LT"
  document_type   = "Automation"
  document_format = "JSON"

  # Load your existing Linux runbook JSON
  content = file(var.linux_runbook_path)

  # Share with specific accounts if needed (optional)
  permissions = length(var.document_target_account_ids) > 0 ? {
    type        = "Share"
    account_ids = join(",", var.document_target_account_ids)
  } : null
}


# ==============================================================================
# PART 2 — LAMBDA SCHEDULER + EVENTBRIDGE
# (Previously: lambda_ssmautomation module)
#
# Wiring notes: this part previously took the SSM automation role ARN and the
# two runbook names as plain input variables that had to match Part 1's
# outputs by hand. They're now wired directly to Part 1's resources below, so
# there's nothing to keep in sync between two deployments any more.
# ==============================================================================

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
    sid    = "DescribeASGAndEC2"
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "ec2:DescribeInstances",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeImages"
    ]
    resources = ["*"]
  }

  # EventBridge Scheduler: create / update schedules
  # (Using Scheduler's API; not legacy EventBridge Rules)
  statement {
    sid    = "ManageScheduler"
    effect = "Allow"
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
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "MiscRead"
    effect = "Allow"
    actions = [
      "sts:GetCallerIdentity"
    ]
    resources = ["*"]
  }

  # allow Lambda to pass the Scheduler execution role to EventBridge Scheduler
  statement {
    sid       = "PassSchedulerExecutionRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
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
# + allow pass of the SSM Automation role (created in Part 1) to SSM
data "aws_iam_policy_document" "scheduler_permissions" {
  statement {
    sid     = "StartAutomation"
    effect  = "Allow"
    actions = ["ssm:StartAutomationExecution"]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:document/${aws_ssm_document.update_windows_ami_with_lt.name}",
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:document/${aws_ssm_document.update_linux_ami_with_lt.name}",
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:automation-execution/*"
    ]
  }

  statement {
    sid       = "PassAutomationAssumeRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.ssm_automation_role.arn]
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
  function_name     = var.lambda_name
  description       = "Discovers ASGs, detects OS, and creates EventBridge Scheduler schedules for SSM automation runbooks."
  role              = aws_iam_role.lambda_exec.arn
  handler           = "auto_schedule_ssm.lambda_handler"
  runtime           = "python3.12"
  filename          = data.archive_file.lambda_zip.output_path
  source_code_hash  = data.archive_file.lambda_zip.output_base64sha256
  timeout           = var.lambda_timeout_sec
  memory_size       = var.lambda_memory_mb

  environment {
    variables = {
      WINDOWS_RUNBOOK              = aws_ssm_document.update_windows_ami_with_lt.name
      LINUX_RUNBOOK                = aws_ssm_document.update_linux_ami_with_lt.name
      IAM_INSTANCE_PROFILE_NAME    = var.ec2_instance_profile_name
      AUTOMATION_ASSUME_ROLE_ARN   = aws_iam_role.ssm_automation_role.arn
      INSTANCE_TYPE                = var.instance_type
      SUBNET_ID                    = var.subnet_id
      SECURITY_GROUP_IDS           = join(",", var.security_group_ids)
      TRIGGER_INSTANCE_REFRESH     = var.trigger_instance_refresh
      SCHEDULER_EXECUTION_ROLE_ARN = aws_iam_role.scheduler_exec.arn
      SCHEDULE_PREFIX              = var.schedule_prefix
      SCHEDULE_HOUR_UTC            = tostring(var.schedule_hour_utc)
      TIMEZONE                     = var.schedule_timezone
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
    "source" : ["aws.autoscaling"],
    "detail-type" : ["AWS API Call via CloudTrail"],
    "detail" : {
      "eventName" : ["CreateAutoScalingGroup"]
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
  count               = var.lambda_scheduled_trigger_enabled ? 1 : 0
  name                = "${var.lambda_name}_scheduled-trigger"
  description         = var.lambda_trigger_description
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
