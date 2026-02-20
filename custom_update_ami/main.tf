terraform {
  required_version = ">= 1.4.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

provider "aws" {
  region = "eu-west-2"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}


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
    sid     = "EC2Read"
    effect  = "Allow"
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
    sid     = "EC2WriteCore"
    effect  = "Allow"
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
    sid     = "PassInstanceProfileRoleToEC2"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [var.instance_profile_role_arn]

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
      sid     = "ASGInstanceRefresh"
      effect  = "Allow"
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