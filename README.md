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

