import boto3
import hashlib
import json
import os
from botocore.exceptions import ClientError

# -------- AWS clients --------
ASG = boto3.client("autoscaling")
EC2 = boto3.client("ec2")
SCHED = boto3.client("scheduler")   # EventBridge Scheduler
STS = boto3.client("sts")

# -------- Environment variables --------
WINDOWS_RUNBOOK = os.getenv("WINDOWS_RUNBOOK", "Custom-Update-Windows-AMI-With-LT")
LINUX_RUNBOOK   = os.getenv("LINUX_RUNBOOK",   "Custom-Update-Linux-AMI-With-LT")

IAM_INSTANCE_PROFILE_NAME = os.getenv("IAM_INSTANCE_PROFILE_NAME")          # required
AUTOMATION_ASSUME_ROLE     = os.getenv("AUTOMATION_ASSUME_ROLE_ARN")        # required
INSTANCE_TYPE              = os.getenv("INSTANCE_TYPE", "t3.medium")
SUBNET_ID                  = os.getenv("SUBNET_ID", "")                     # optional
TRIGGER_INSTANCE_REFRESH   = os.getenv("TRIGGER_INSTANCE_REFRESH", "true")  # "true"/"false"

# Scheduler execution role (ROLE THAT SCHEDULER ASSUMES when it calls SSM)
EXECUTION_ROLE_ARN         = os.getenv("SCHEDULER_EXECUTION_ROLE_ARN")      # required

# Scheduling options
SCHEDULE_PREFIX            = os.getenv("SCHEDULE_PREFIX", "UpdateAmiForAsg-")
SCHEDULE_HOUR_UTC          = int(os.getenv("SCHEDULE_HOUR_UTC", "3"))
TIMEZONE                   = os.getenv("TIMEZONE", "")  # optional (e.g., Europe/London)

# -------- Helpers --------
def detect_os(image_id: str) -> str:
    """Return 'windows' or 'linux' based on AMI metadata."""
    resp = EC2.describe_images(ImageIds=[image_id])
    img = resp["Images"][0]
    # Prefer PlatformDetails (more descriptive), fall back to Platform
    platform_details = (img.get("PlatformDetails") or "").lower()
    platform = (img.get("Platform") or "").lower()
    if "windows" in platform_details or "windows" in platform:
        return "windows"
    return "linux"


def resolve_template_and_ami(asg: dict):
    """
    Returns (launch_template_id, version_spec, image_id) for an ASG.
    Supports:
      - MixedInstancesPolicy.LaunchTemplate.LaunchTemplateSpecification
      - ASG.LaunchTemplate
    Skips LaunchConfiguration-backed ASGs (returns (None, None, None)).
    """
    mip = asg.get("MixedInstancesPolicy", {})
    if mip:
        lts = (
            mip.get("LaunchTemplate", {})
               .get("LaunchTemplateSpecification", {})
        )
        if lts:
            lt_id = lts.get("LaunchTemplateId")
            version = lts.get("Version", "$Default")
            image_id = _image_from_lt(lt_id, version)
            return lt_id, version, image_id

    lt = asg.get("LaunchTemplate")
    if lt:
        lt_id = lt.get("LaunchTemplateId")
        version = lt.get("Version", "$Default")
        image_id = _image_from_lt(lt_id, version)
        return lt_id, version, image_id

    return None, None, None


def _image_from_lt(lt_id: str, version: str) -> str:
    resp = EC2.describe_launch_template_versions(
        LaunchTemplateId=lt_id,
        Versions=[version],
    )
    data = resp["LaunchTemplateVersions"][0]["LaunchTemplateData"]
    return data.get("ImageId")


def deterministic_minute(asg_name: str) -> int:
    """Deterministic minute 0..59 per ASG to stagger schedules."""
    h = hashlib.sha256(asg_name.encode()).hexdigest()
    return int(h[:2], 16) % 60


def upsert_scheduler_schedule(
    name: str,
    document_name: str,
    params: dict,
    minute: int,
    hour: int,
    timezone: str,
    execution_role_arn: str,
):
    """
    Create or update an EventBridge Scheduler schedule targeting
    SSM StartAutomationExecution.

    NOTE:
      - If CreateSchedule conflicts (name exists), we call UpdateSchedule.
      - For UpdateSchedule we re-send the full expression + target because
        UpdateSchedule overwrites unspecified fields with defaults.  [1](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region)
    """
    cron = f"cron({minute} {hour} ? * SUN#3 *)"  # 3rd Sunday pattern

    input_payload = {
        "DocumentName": document_name,
        "DocumentVersion": "$DEFAULT",
        "Parameters": {k: [str(v)] for k, v in params.items()}
    }
    input_json = json.dumps(input_payload)

    target_arn = "arn:aws:scheduler:::aws-sdk:ssm:startAutomationExecution"  # universal target  [2](https://registry.terraform.io/providers/hashicorp/aws/6.27.0/docs/data-sources/region.html)

    create_args = {
        "Name": name,
        "ScheduleExpression": cron,
        "FlexibleTimeWindow": {"Mode": "OFF"},
        "Target": {
            "Arn": target_arn,
            "RoleArn": execution_role_arn,
            "Input": input_json
        }
    }
    if timezone:
        create_args["ScheduleExpressionTimezone"] = timezone

    try:
        SCHED.create_schedule(**create_args)  # Create schedule  [4](https://registry.terraform.io/providers/hashicorp/aws/6.8.0/docs/data-sources/region)
        return {"action": "created", "name": name, "cron": cron}
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") != "ConflictException":
            raise

    # already exists -> update (re-send full config)  [1](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region)
    update_args = {
        "Name": name,
        "ScheduleExpression": cron,
        "FlexibleTimeWindow": {"Mode": "OFF"},
        "Target": {
            "Arn": target_arn,
            "RoleArn": execution_role_arn,
            "Input": input_json
        }
    }
    if timezone:
        update_args["ScheduleExpressionTimezone"] = timezone

    SCHED.update_schedule(**update_args)  # Update schedule  [1](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region)[5](https://github.com/terraform-aws-modules/terraform-aws-notify-slack/issues/255)
    return {"action": "updated", "name": name, "cron": cron}


# -------- Lambda handler --------
def lambda_handler(event, context):
    # Basic validation
    missing = []
    if not IAM_INSTANCE_PROFILE_NAME:
        missing.append("IAM_INSTANCE_PROFILE_NAME")
    if not AUTOMATION_ASSUME_ROLE:
        missing.append("AUTOMATION_ASSUME_ROLE_ARN")
    if not EXECUTION_ROLE_ARN:
        missing.append("SCHEDULER_EXECUTION_ROLE_ARN")
    if missing:
        raise RuntimeError(f"Missing required env var(s): {', '.join(missing)}")

    _ = STS.get_caller_identity()  # touch STS for sanity/logging

    paginator = ASG.get_paginator("describe_auto_scaling_groups")
    results = []

    for page in paginator.paginate():
        for asg in page["AutoScalingGroups"]:
            asg_name = asg["AutoScalingGroupName"]

            lt_id, lt_ver, ami = resolve_template_and_ami(asg)
            if not lt_id or not ami:
                # Skip LaunchConfiguration-backed or malformed ASGs
                results.append({"asg": asg_name, "skipped": True, "reason": "no_launch_template_or_ami"})
                continue

            os_type = detect_os(ami)
            document = WINDOWS_RUNBOOK if os_type == "windows" else LINUX_RUNBOOK

            # Build SSM parameters (list-of-strings applied by upsert helper)
            parameters = {
                "LaunchTemplateId": lt_id,
                "AutoScalingGroupName": asg_name,
                "IamInstanceProfileName": IAM_INSTANCE_PROFILE_NAME,
                "AutomationAssumeRole": AUTOMATION_ASSUME_ROLE,
                "InstanceType": INSTANCE_TYPE,
                "TriggerInstanceRefresh": TRIGGER_INSTANCE_REFRESH,
            }
            if SUBNET_ID:
                parameters["SubnetId"] = SUBNET_ID

            # Stagger minutes deterministically by ASG name
            minute = deterministic_minute(asg_name)
            schedule_name = f"{SCHEDULE_PREFIX}{asg_name}"

            result = upsert_scheduler_schedule(
                name=schedule_name,
                document_name=document,
                params=parameters,
                minute=minute,
                hour=SCHEDULE_HOUR_UTC,
                timezone=TIMEZONE,
                execution_role_arn=EXECUTION_ROLE_ARN,  # <-- required argument
            )

            results.append({
                "asg": asg_name,
                "launch_template_id": lt_id,
                "ami": ami,
                "os": os_type,
                "schedule": schedule_name,
                "action": result["action"],
                "cron": result["cron"],
            })

    return {"status": "ok", "schedules": results}