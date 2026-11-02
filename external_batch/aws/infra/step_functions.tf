# ----------------------------------------------------------- Step Functions
# Optional AWS Step Functions state machine orchestrating AWS Batch array jobs,
# fault-tolerant retry policies, and automated cloud-side finalization.

variable "enable_step_functions" {
  description = "Whether to provision AWS Step Functions state machine orchestration"
  type        = bool
  default     = false
}

variable "existing_step_functions_role_arn" {
  description = "Existing IAM role ARN for Step Functions when create_iam_and_security_group is false"
  type        = string
  default     = ""
}

variable "enable_step_functions_sns_notification" {
  description = "Whether to publish completion notifications to SNS from the state machine"
  type        = bool
  default     = false
}

variable "step_functions_sns_topic_arn" {
  description = "SNS Topic ARN for completion notifications (optional)"
  type        = string
  default     = ""
}

# ------------------------------------------------ IAM (Step Functions Role)

resource "aws_iam_role" "step_functions" {
  count = var.enable_step_functions && var.create_iam_and_security_group ? 1 : 0
  name  = "${var.name_prefix}-step-functions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "states.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "step_functions" {
  count = var.enable_step_functions && var.create_iam_and_security_group ? 1 : 0
  name  = "${var.name_prefix}-step-functions-policy"
  role  = aws_iam_role.step_functions[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBatchManagement"
        Effect = "Allow"
        Action = [
          "batch:SubmitJob",
          "batch:DescribeJobs",
          "batch:TerminateJob",
          "batch:CancelJob"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowEventBridgeForSyncTask"
        Effect = "Allow"
        Action = [
          "events:PutTargets",
          "events:PutRule",
          "events:DescribeRule"
        ]
        Resource = [
          "arn:aws:events:*:*:rule/StepFunctionsGetEventsForBatchJobsRule*"
        ]
      },
      {
        Sid    = "AllowS3Access"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.batch.arn,
          "${aws_s3_bucket.batch.arn}/*"
        ]
      },
      {
        Sid    = "AllowCloudWatchLogsDelivery"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowSnsPublish"
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = "*"
      }
    ]
  })
}

locals {
  step_functions_role_arn = var.create_iam_and_security_group ? (
    length(aws_iam_role.step_functions) > 0 ? aws_iam_role.step_functions[0].arn : ""
  ) : var.existing_step_functions_role_arn
}

# ------------------------------------------------ CloudWatch Logs for SFN

resource "aws_cloudwatch_log_group" "step_functions" {
  count             = var.enable_step_functions ? 1 : 0
  name              = "/aws/vendedlogs/states/${var.name_prefix}-orchestrator"
  retention_in_days = 14
}

# ------------------------------------------------ State Machine

resource "aws_sfn_state_machine" "batch_orchestrator" {
  count    = var.enable_step_functions && local.step_functions_role_arn != "" ? 1 : 0
  name     = "${var.name_prefix}-orchestrator"
  role_arn = local.step_functions_role_arn

  definition = file("${path.module}/../orchestration/state_machine.asl.json")

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.step_functions[0].arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }
}

# ------------------------------------------------ Outputs

output "step_functions_state_machine_arn" {
  description = "ARN of the Step Functions batch orchestrator state machine"
  value       = length(aws_sfn_state_machine.batch_orchestrator) > 0 ? aws_sfn_state_machine.batch_orchestrator[0].arn : ""
}

output "step_functions_state_machine_name" {
  description = "Name of the Step Functions batch orchestrator state machine"
  value       = length(aws_sfn_state_machine.batch_orchestrator) > 0 ? aws_sfn_state_machine.batch_orchestrator[0].name : ""
}
