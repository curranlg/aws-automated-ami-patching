# Automated AMI Lifecycle & Patch Management for Auto Scaling Groups

This solution provides a fully automated, high availability workflow that keeps all EC2 Auto Scaling Groups up to date with the latest Windows or Linux AMIs—without impacting application uptime. It discovers ASGs, determines their operating system, builds updated AMIs through SSM Automation runbooks, updates Launch Templates, and then performs a safe Rolling Instance Refresh designed to prioritize availability. 

EventBridge ensures the process runs automatically whenever new ASGs are created or on a user defined schedule, delivering a hands off, resilient, and compliant patching model aligned to AWS best practices.

<img src="https://github.com/liamgcurran/automated-ami-patching/blob/main/Automated-AMI-Lifecycle-Patch-Management-For-ASGs-2.jpg">

# Prerequisites (important)
•	All EC2’s instances must have an instance profile attached that allows access to SSM

•	ASG’s must use a Launch Template (not legacy Launch Configurations).

•	Currently doesn't work for Windows 2025  (the AWS provided SSM-UpdateWindowsAMI runbook only works up to Windows 2022)

# High Level Solution Overview
•	Lambda automatically triggers whenever a new Auto Scaling Group (ASG) is created (via an EventBridge Rule on the CreateAutoScalingGroup CloudTrail event) or on a user defined schedule i.e. on the 1st of every month.

•	Lambda discovers all ASGs in the account/region using Auto Scaling APIs and identifies the Launch Template associated with each.

•	Lambda queries the Launch Template to extract the AMI ID currently used by the ASG.

•	Lambda queries EC2 AMI metadata to determine whether the ASG is running Windows or Linux.

•	Lambda selects the correct SSM Automation runbook (Custom-Update-Windows-AMI-With-LT or Custom-Update-Linux-AMI-With-LT) based on the detected OS.

•	Lambda creates or updates an EventBridge Scheduler schedule per ASG, using a deterministic per ASG minute to avoid concurrency spikes.

•	Each schedule invokes SSM Automation using the universal AWS SDK target to start an AMI update workflow.

•	SSM Automation runbook launches a temporary builder instance, patches it, creates a new AMI, tags the AMI, and updates the ASG’s Launch Template with the new AMI.

•	Automation then triggers an Auto Scaling Instance Refresh using the "Rolling" strategy and availability focused preferences (MinHealthyPercentage, warmup, etc.) to ensure zero downtime rollout.

•	ASG replaces instances safely and gradually, ensuring at least the defined number of healthy nodes remain available throughout the refresh process.


# Automated AMI Patching — combined module

This folder merges the previous two-step deployment (`custom_update_ami` +
`lambda_ssmautomation`) into a single Terraform configuration/module.

## What changed

- **One `terraform apply` instead of two.** All resources live in one root
  module (`main.tf`, `variables.tf`, `outputs.tf`), with `runbooks/` and
  `lambda/` copied in as-is.
- **Automatic wiring between the two halves.** Previously you had to copy the
  SSM automation role ARN and the two runbook document names out of one
  stack's outputs and paste them into the other stack's `terraform.tfvars`.
  Now those are direct Terraform references
  (`aws_iam_role.ssm_automation_role.arn`,
  `aws_ssm_document.update_windows_ami_with_lt.name`, etc.), so they can never
  drift out of sync.
- **One instance-profile input instead of two.** You used to supply
  `instance_profile_role_arn` to the first stack and
  `iam_instance_profile_name` to the second — two different ways of
  describing the same instance profile. Now you supply just
  `ec2_instance_profile_name`, and the role ARN is looked up automatically
  with a `data "aws_iam_instance_profile"` source.
- Resource **names/types are unchanged** from the originals — this matters
  for migrating existing state (see below).

## Fresh deployment (no existing resources)

bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — at minimum set ec2_instance_profile_name

terraform init
terraform plan
terraform apply


## Migrating from the previous two-state deployment into this combined module

Because every resource keeps its original Terraform address
(`aws_iam_role.ssm_automation_role`, `aws_lambda_function.asg_ami_scheduler`,
etc.), you don't need to destroy/recreate anything in AWS — you just need to
move the state entries into one state file.

1. Put this combined config somewhere new, and `terraform init` it (with
   whatever backend you want the merged state to live in).

2. Pull each resource address out of your two existing states into the new
   one. If your old states are local files:

   ```bash
   # from custom_update_ami's old state
   for addr in $(terraform state list -state=/path/to/custom_update_ami/terraform.tfstate); do
     terraform state mv -state=/path/to/custom_update_ami/terraform.tfstate \
       -state-out=terraform.tfstate "$addr" "$addr"
   done

   # from lambda_ssmautomation's old state
   for addr in $(terraform state list -state=/path/to/lambda_ssmautomation/terraform.tfstate); do
     terraform state mv -state=/path/to/lambda_ssmautomation/terraform.tfstate \
       -state-out=terraform.tfstate "$addr" "$addr"
   done
   ```

   If you're using a remote backend (S3, etc.) instead of local files, run the
   same `terraform state mv` commands from within each old directory,
   targeting the new backend with `-state-out`, or use `terraform state pull` /
   `push` to stitch the JSON together — same idea either way.

3. `terraform plan` in the combined directory. Because the resource addresses
   line up, this should come back with **no changes** — that's your
   confirmation the migration was clean. Two things it will legitimately want
   to change, since they were previously separate variables re-typed by hand:
   - the `iam:PassRole` resource on `automation_permissions` (now points at
     the instance profile's role ARN via a data source instead of a raw
     var — same value, should be a no-op if you passed matching values
     before)
   - nothing else, if your old `terraform.tfvars` values matched between the
     two stacks as the README always assumed they would

4. Once `plan` is clean, delete the two old working directories/state files
   and use this one going forward.

## Files

| File | Purpose |
|---|---|
| `main.tf` | All resources: SSM automation role + documents, Lambda + IAM roles, EventBridge rules |
| `variables.tf` | Inputs (see `terraform.tfvars.example`) |
| `outputs.tf` | Role ARNs / names other stacks might reference |
| `runbooks/*.json` | SSM Automation runbook documents (Windows/Linux) |
| `lambda/auto_schedule_ssm.py` | Lambda source, packaged automatically via the `archive` provider |

