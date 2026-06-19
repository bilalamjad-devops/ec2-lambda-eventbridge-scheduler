# Stop Paying for Idle EC2 Instances: Automated Scheduling with Terraform, Lambda & EventBridge
 
If your team runs non-production EC2 instances — dev, test, staging — there's a good chance they're running 24/7 even though people only touch them during office hours. That's wasted spend, plain and simple. An instance that's only needed from 8 AM to 5 PM, Monday to Friday, is being billed for roughly 16 unused hours a day and the entire weekend.
 
In this post, I'll walk through a serverless solution that fixes this automatically: **Terraform** provisions the infrastructure, **AWS Lambda** runs the start/stop logic, and **Amazon EventBridge** triggers it on a schedule. No cron jobs on a server, no manual reminders, no one logging in at 5 PM to hit "stop."
 
By the end, you'll have a working pipeline that:
- Tags EC2 instances as eligible for auto-scheduling
- Starts them automatically at the beginning of the workday
- Stops them automatically at the end of the workday
- Is fully reproducible with `terraform apply` / `terraform destroy`
## Why Lambda + EventBridge
 
- **Cost-effective** — Lambda only charges for execution time. This workload runs for seconds, twice a day. The cost is effectively a few cents a month.
- **No servers to maintain** — AWS runs the scheduler infrastructure; there's nothing for you to patch or monitor for uptime.
- **Tag-driven, not blanket** — only instances explicitly tagged opt into this behavior, so you can't accidentally affect production.
- **Auditable** — every start/stop action is logged in CloudWatch, so you can trace exactly what happened and when.
## How It Works
 
1. You tag the EC2 instances you want managed with `AutoSchedule = True`.
2. EventBridge fires a rule at 8:00 AM PKT (start) and another at 5:00 PM PKT (stop), Monday–Friday.
3. Each rule invokes a Lambda function.
4. The Lambda function queries EC2 for instances matching the tag and the right state (`stopped` for the start function, `running` for the stop function), then calls `start_instances` or `stop_instances` on them.
5. Terraform provisions all of this — the IAM role, both Lambda functions, both EventBridge rules, and the permissions linking them — in one `apply`.
## Prerequisites
 
- An AWS account with programmatic access (access key + secret key)
- [Terraform](https://developer.hashicorp.com/terraform/downloads) installed and on your PATH
- A code editor (VS Code works fine)
- Basic familiarity with the AWS Console
I won't walk through installing Terraform step by step here — the [official docs](https://developer.hashicorp.com/terraform/downloads) cover that well for any OS. Once `terraform -v` works in your terminal, you're ready.
 
## Project Structure
 
```
.
├── main.tf
└── python/
    ├── start_ec2_instances.py
    └── stop_ec2_instances.py
```
 
## A Quick Note on Credentials
 
You'll see some versions of this tutorial put the AWS access key and secret key directly inside `main.tf`. **Don't do that** — if you ever push this to GitHub, you've just leaked your AWS credentials publicly, and that account can be compromised within minutes.
 
Instead, configure your credentials once via the AWS CLI:
 
```bash
aws configure
```
 
This stores them in `~/.aws/credentials`, and Terraform will pick them up automatically. Your `main.tf` never needs to reference a key directly.
 
## The Terraform Configuration
 
```hcl
# main.tf
 
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.74.0" # Lock to a specific version for consistency
    }
  }
}
 
provider "aws" {
  region = "ap-south-1" # change to your preferred region
}
 
# --- IAM Role for Lambda Functions ---
# Shared by both Lambda functions.
resource "aws_iam_role" "ec2_scheduler_lambda_role" {
  name = "EC2SchedulerLambdaRole"
 
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
 
  tags = {
    ManagedBy = "Terraform"
    Purpose   = "EC2 Scheduler"
  }
}
 
# --- IAM Policy: what the Lambda functions are allowed to do ---
resource "aws_iam_role_policy" "ec2_scheduler_lambda_policy" {
  name = "EC2SchedulerLambdaPolicy"
  role = aws_iam_role.ec2_scheduler_lambda_role.id
 
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ec2:DescribeInstances",
          "ec2:StartInstances",
          "ec2:StopInstances",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "*" # fine for a lab; scope this down to specific ARNs in production
      }
    ]
  })
}
 
# --- Package the Python code into zip files Lambda can deploy ---
data "archive_file" "start_ec2_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/python/start_ec2_instances.py"
  output_path = "${path.module}/python/start_ec2_instances.zip"
}
 
data "archive_file" "stop_ec2_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/python/stop_ec2_instances.py"
  output_path = "${path.module}/python/stop_ec2_instances.zip"
}
 
# --- Lambda: Start EC2 Instances ---
resource "aws_lambda_function" "start_ec2_function" {
  function_name    = "StartEC2Daily"
  role             = aws_iam_role.ec2_scheduler_lambda_role.arn
  handler          = "start_ec2_instances.lambda_handler"
  runtime          = "python3.9"
  timeout          = 60
  memory_size      = 128
 
  filename         = data.archive_file.start_ec2_lambda_zip.output_path
  source_code_hash = data.archive_file.start_ec2_lambda_zip.output_base64sha256
 
  tags = {
    ManagedBy = "Terraform"
    Purpose   = "EC2 Scheduler Start"
  }
}
 
# --- Lambda: Stop EC2 Instances ---
resource "aws_lambda_function" "stop_ec2_function" {
  function_name    = "StopEC2Daily"
  role             = aws_iam_role.ec2_scheduler_lambda_role.arn
  handler          = "stop_ec2_instances.lambda_handler"
  runtime          = "python3.9"
  timeout          = 60
  memory_size      = 128
 
  filename         = data.archive_file.stop_ec2_lambda_zip.output_path
  source_code_hash = data.archive_file.stop_ec2_lambda_zip.output_base64sha256
 
  tags = {
    ManagedBy = "Terraform"
    Purpose   = "EC2 Scheduler Stop"
  }
}
 
# --- EventBridge Rule: Start at 8:00 AM PKT (03:00 UTC), Mon–Fri ---
resource "aws_cloudwatch_event_rule" "start_ec2_schedule_rule" {
  name                = "start-ec2-daily-schedule"
  description         = "Start EC2 instances daily at 8:00 AM PKT"
  schedule_expression = "cron(0 3 ? * MON-FRI *)"
 
  tags = {
    ManagedBy = "Terraform"
    Purpose   = "EC2 Scheduler Start"
  }
}
 
resource "aws_cloudwatch_event_target" "start_ec2_lambda_target" {
  rule      = aws_cloudwatch_event_rule.start_ec2_schedule_rule.name
  target_id = "StartEC2Lambda"
  arn       = aws_lambda_function.start_ec2_function.arn
}
 
resource "aws_lambda_permission" "allow_cloudwatch_to_invoke_start_lambda" {
  statement_id  = "AllowExecutionFromCloudWatchStart"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_ec2_function.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.start_ec2_schedule_rule.arn
}
 
# --- EventBridge Rule: Stop at 5:00 PM PKT (12:00 UTC), Mon–Fri ---
resource "aws_cloudwatch_event_rule" "stop_ec2_schedule_rule" {
  name                = "stop-ec2-daily-schedule"
  description         = "Stop EC2 instances daily at 5:00 PM PKT"
  schedule_expression = "cron(0 12 ? * MON-FRI *)"
 
  tags = {
    ManagedBy = "Terraform"
    Purpose   = "EC2 Scheduler Stop"
  }
}
 
resource "aws_cloudwatch_event_target" "stop_ec2_lambda_target" {
  rule      = aws_cloudwatch_event_rule.stop_ec2_schedule_rule.name
  target_id = "StopEC2Lambda"
  arn       = aws_lambda_function.stop_ec2_function.arn
}
 
resource "aws_lambda_permission" "allow_cloudwatch_to_invoke_stop_lambda" {
  statement_id  = "AllowExecutionFromCloudWatchStop"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stop_ec2_function.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.stop_ec2_schedule_rule.arn
}
```
 
A couple of things worth understanding rather than just copying:
 
- **AWS cron always runs in UTC.** Pakistan Standard Time is UTC+5, so 8:00 AM PKT becomes `cron(0 3 ...)` and 5:00 PM PKT becomes `cron(0 12 ...)`. If you're in a different timezone, do that conversion yourself before deploying.
- **The `?` in the cron expression** means "don't care" for day-of-month, because we're already specifying days via `MON-FRI`. AWS cron requires exactly one of day-of-month or day-of-week to be `?`.
## The Lambda Functions
 
Both functions follow the same pattern: filter EC2 instances by tag and current state, then act on whatever matches.
 
**`python/start_ec2_instances.py`**
 
```python
import boto3
import os
 
ec2 = boto3.client('ec2')
 
TAG_KEY = os.environ.get('TAG_KEY', 'AutoSchedule')
TAG_VALUE = os.environ.get('TAG_VALUE', 'True')
 
def lambda_handler(event, context):
    print("--- Starting EC2 instances process initiated ---")
    print(f"Looking for instances with tag '{TAG_KEY}':'{TAG_VALUE}'")
 
    filters = [
        {'Name': 'instance-state-name', 'Values': ['stopped']},
        {'Name': f'tag:{TAG_KEY}', 'Values': [TAG_VALUE]}
    ]
 
    instances_to_start = []
    try:
        response = ec2.describe_instances(Filters=filters)
        for reservation in response['Reservations']:
            for instance in reservation['Instances']:
                instances_to_start.append(instance['InstanceId'])
 
        if instances_to_start:
            print(f"Found {len(instances_to_start)} instances to start: {instances_to_start}")
            ec2.start_instances(InstanceIds=instances_to_start)
            print("Successfully sent start command to EC2 instances.")
        else:
            print("No stopped instances found with the specified tag.")
 
    except Exception as e:
        print(f"Error starting EC2 instances: {e}")
        return {'statusCode': 500, 'body': f"Error starting EC2 instances: {str(e)}"}
 
    print("--- EC2 instances start process completed ---")
    return {'statusCode': 200, 'body': 'EC2 instance start process completed.'}
```
 
**`python/stop_ec2_instances.py`**
 
```python
import boto3
import os
 
ec2 = boto3.client('ec2')
 
TAG_KEY = os.environ.get('TAG_KEY', 'AutoSchedule')
TAG_VALUE = os.environ.get('TAG_VALUE', 'True')
 
def lambda_handler(event, context):
    print("--- Stopping EC2 instances process initiated ---")
    print(f"Looking for instances with tag '{TAG_KEY}':'{TAG_VALUE}'")
 
    filters = [
        {'Name': 'instance-state-name', 'Values': ['running']},
        {'Name': f'tag:{TAG_KEY}', 'Values': [TAG_VALUE]}
    ]
 
    instances_to_stop = []
    try:
        response = ec2.describe_instances(Filters=filters)
        for reservation in response['Reservations']:
            for instance in reservation['Instances']:
                # In production, you might add extra checks here — e.g. exclude
                # instances in an Auto Scaling Group, or honor a "DoNotStop" tag.
                instances_to_stop.append(instance['InstanceId'])
 
        if instances_to_stop:
            print(f"Found {len(instances_to_stop)} instances to stop: {instances_to_stop}")
            ec2.stop_instances(InstanceIds=instances_to_stop)
            print("Successfully sent stop command to EC2 instances.")
        else:
            print("No running instances found with the specified tag.")
 
    except Exception as e:
        print(f"Error stopping EC2 instances: {e}")
        return {'statusCode': 500, 'body': f"Error stopping EC2 instances: {str(e)}"}
 
    print("--- EC2 instances stop process completed ---")
    return {'statusCode': 200, 'body': 'EC2 instance stop process completed.'}
```
 
Notice both scripts read `TAG_KEY` and `TAG_VALUE` from environment variables with sensible defaults — so you can reuse this for a different tag (e.g. `Environment: dev`) without touching the code.
 
## Deploying It
 
```bash
terraform init
terraform plan
terraform apply
```
 
Type `yes` when prompted. Terraform will create the IAM role, both Lambda functions, both EventBridge rules, and wire the permissions between them.
 
## Testing It Yourself
 
1. **Launch a test EC2 instance** (a free-tier `t2.micro` is fine) and tag it `AutoSchedule = True` during launch, under "Add additional tags."
2. **Set its initial state to match the next scheduled action**:
   - Testing before 8 AM PKT? Stop the instance — the 8 AM rule will start it.
   - Testing between 8 AM and 5 PM PKT? Leave it running — the 5 PM rule will stop it.
3. **Verify the EventBridge rules** in the console (EventBridge → Rules) — confirm the cron expressions match what's in the Terraform code, and double-check the UTC-to-local conversion.
4. **Verify the Lambda functions** exist (Lambda → Functions) with the correct runtime (Python 3.9), handler, and the `EC2SchedulerLambdaRole` attached under Permissions.
5. **Check CloudWatch Logs** under `/aws/lambda/StartEC2Daily` and `/aws/lambda/StopEC2Daily` to confirm each invocation ran and found the right instances.
6. **Watch the EC2 console** at the scheduled time — your tagged instance should flip from `stopped` to `running` (or vice versa) within a few minutes of the cron trigger.
## Cleaning Up
 
Don't leave lab resources running after you're done testing:
 
```bash
terraform destroy
```
 
Type `yes` to confirm. Then manually terminate any EC2 instance you launched by hand for testing, since Terraform never managed that instance directly — it only manages the scheduler infrastructure.
 
## Wrapping Up
 
This is a small project, but it covers a lot of ground that shows up in real DevOps work: Infrastructure as Code with Terraform, event-driven serverless functions, IAM least-privilege thinking, and a tagging strategy that scales to dozens of instances without code changes. The same pattern — tag a resource, let a scheduled Lambda act on it — extends easily to RDS instances, ASGs, or any other resource with a start/stop API.
 
If you're managing non-prod AWS environments and they're running unattended overnight or on weekends, this is a low-effort way to claw back real savings.
 
---
 
*Code for this project is available on [GitHub](#) — link your repo here.*
