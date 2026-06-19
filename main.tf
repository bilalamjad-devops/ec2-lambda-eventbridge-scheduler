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
