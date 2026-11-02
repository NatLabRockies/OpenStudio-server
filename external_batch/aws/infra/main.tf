# One-time AWS infrastructure for external batch runs (run `terraform apply` once).
# Creates: S3 bucket (the transport hub), ECR repo (runner image), AWS Batch
# compute environment + job queue + job definition, and least-privilege IAM.
#
# Design notes (from doc/external_batch_plan.md prior-art review):
# - ON-DEMAND instances (not spot) by default; BEST_FIT_PROGRESSIVE allocation.
# - m6idn/m5d families: the local NVMe keeps EnergyPlus small-file I/O off EBS.
# - 1 vCPU + ~8 GB per container: one sim at a time per array task; array size
#   (= number of chunks) is the parallelism knob.
# - Workers get an IAM TASK ROLE scoped to this bucket's runs/ prefix — no AWS
#   keys ever enter a container.
# - MIN_VCPUS = 0: the fleet scales to zero between analyses.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ------------------------------------------------------------------ variables

variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-west-2"
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "osaf-batch"
}

variable "bucket_name" {
  description = "S3 bucket for batch packages/results (must be globally unique)"
  type        = string
}

variable "max_vcpus" {
  description = "Compute environment ceiling (1 vCPU = 1 concurrent simulation)"
  type        = number
  default     = 256
}

variable "container_memory_mb" {
  description = "Memory per array task in MB (8192 MB = 8 GB for 1 vCPU)"
  type        = number
  default     = 8192
}

variable "runner_image_tag" {
  description = "Tag of the runner image in the ECR repo (e.g. the OpenStudio version)"
  type        = string
  default     = "3.11.0"
}

variable "results_expire_days" {
  description = "Days before runs/ objects auto-expire in S3 (0 = keep forever)"
  type        = number
  default     = 30
}

variable "subnet_ids" {
  description = "Subnets for the compute environment (default: default VPC subnets)"
  type        = list(string)
  default     = []
}

variable "vpc_id" {
  description = "VPC for the compute environment security group (default: default VPC)"
  type        = string
  default     = ""
}

# ------------------------------------ existing IAM / enterprise configuration

variable "create_iam_and_security_group" {
  description = "Whether to create IAM roles and security group. Set to false in restricted accounts where these are pre-provisioned."
  type        = bool
  default     = true
}

variable "existing_service_role_arn" {
  description = "Existing Batch service role ARN (used when create_iam_and_security_group is false)"
  type        = string
  default     = ""
}

variable "existing_instance_role_arn" {
  description = "Existing ECS instance profile ARN for EC2 (used when create_iam_and_security_group is false and compute_platform is EC2)"
  type        = string
  default     = ""
}

variable "existing_task_role_arn" {
  description = "Existing ECS task role ARN for the runner container (used when create_iam_and_security_group is false)"
  type        = string
  default     = ""
}

variable "existing_execution_role_arn" {
  description = "Existing ECS task execution role ARN (required for FARGATE image pull/logs)"
  type        = string
  default     = ""
}

variable "existing_security_group_ids" {
  description = "Existing security group IDs (used when create_iam_and_security_group is false)"
  type        = list(string)
  default     = []
}

variable "compute_platform" {
  description = "Compute platform: EC2 or FARGATE_SPOT / FARGATE"
  type        = string
  default     = "EC2"
}

# ------------------------------------------------------- default VPC fallback

data "aws_vpc" "default" {
  count   = var.vpc_id == "" ? 1 : 0
  default = true
}

locals {
  vpc_id = var.vpc_id != "" ? var.vpc_id : data.aws_vpc.default[0].id

  is_fargate = upper(var.compute_platform) == "FARGATE" || upper(var.compute_platform) == "FARGATE_SPOT"

  service_role_arn  = var.create_iam_and_security_group ? aws_iam_role.batch_service[0].arn : var.existing_service_role_arn
  instance_role_arn = local.is_fargate ? null : (var.create_iam_and_security_group ? aws_iam_instance_profile.ecs_instance[0].arn : var.existing_instance_role_arn)
  task_role_arn     = var.create_iam_and_security_group ? aws_iam_role.task[0].arn : var.existing_task_role_arn
  execution_role_arn = local.is_fargate ? var.existing_execution_role_arn : null

  security_group_ids = var.create_iam_and_security_group ? [aws_security_group.batch[0].id] : (
    length(var.existing_security_group_ids) > 0 ? var.existing_security_group_ids : []
  )
}

data "aws_subnets" "default" {
  count = length(var.subnet_ids) == 0 ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
}

locals {
  subnet_ids = length(var.subnet_ids) > 0 ? var.subnet_ids : data.aws_subnets.default[0].ids
}

# ------------------------------------------------------------------------- S3

resource "aws_s3_bucket" "batch" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "batch" {
  bucket                  = aws_s3_bucket.batch.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "batch" {
  count  = var.results_expire_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.batch.id
  rule {
    id     = "expire-runs"
    status = "Enabled"
    filter {
      prefix = "runs/"
    }
    expiration {
      days = var.results_expire_days
    }
  }
}

resource "aws_s3_bucket_policy" "task_access" {
  count  = local.task_role_arn != "" ? 1 : 0
  bucket = aws_s3_bucket.batch.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowBatchTaskAccess"
        Effect    = "Allow"
        Principal = {
          AWS = local.task_role_arn
        }
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          aws_s3_bucket.batch.arn,
          "${aws_s3_bucket.batch.arn}/*"
        ]
      }
    ]
  })
}

# ------------------------------------------------------------------------ ECR

resource "aws_ecr_repository" "runner" {
  name                 = "${var.name_prefix}-runner"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

# ------------------------------------------------------------------------ IAM
# Optional role creation (skipped when create_iam_and_security_group is false)

resource "aws_iam_role" "batch_service" {
  count = var.create_iam_and_security_group ? 1 : 0
  name  = "${var.name_prefix}-service-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "batch.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "batch_service" {
  count      = var.create_iam_and_security_group ? 1 : 0
  role       = aws_iam_role.batch_service[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

resource "aws_iam_role" "ecs_instance" {
  count = var.create_iam_and_security_group && !local.is_fargate ? 1 : 0
  name  = "${var.name_prefix}-instance-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_instance" {
  count      = var.create_iam_and_security_group && !local.is_fargate ? 1 : 0
  role       = aws_iam_role.ecs_instance[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  count = var.create_iam_and_security_group && !local.is_fargate ? 1 : 0
  name  = "${var.name_prefix}-instance-profile"
  role  = aws_iam_role.ecs_instance[0].name
}

resource "aws_iam_role" "task" {
  count = var.create_iam_and_security_group ? 1 : 0
  name  = "${var.name_prefix}-task-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ecs-tasks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "task_s3" {
  count = var.create_iam_and_security_group ? 1 : 0
  name  = "${var.name_prefix}-task-s3"
  role  = aws_iam_role.task[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.batch.arn
        Condition = { StringLike = { "s3:prefix" = "runs/*" } }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.batch.arn}/runs/*"
      }
    ]
  })
}

# ---------------------------------------------------------------------- Batch

resource "aws_security_group" "batch" {
  count       = var.create_iam_and_security_group ? 1 : 0
  name        = "${var.name_prefix}-sg"
  description = "OSAF external batch compute (egress only)"
  vpc_id      = local.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_batch_compute_environment" "batch" {
  name         = "${var.name_prefix}-ce"
  type         = "MANAGED"
  service_role = local.service_role_arn

  compute_resources {
    type                = local.is_fargate ? (upper(var.compute_platform) == "FARGATE_SPOT" ? "FARGATE_SPOT" : "FARGATE") : "EC2"
    allocation_strategy = local.is_fargate ? null : "BEST_FIT_PROGRESSIVE"
    instance_role       = local.instance_role_arn
    instance_type       = local.is_fargate ? null : ["m6idn", "m5d"]
    min_vcpus           = local.is_fargate ? null : 0
    max_vcpus           = var.max_vcpus
    security_group_ids  = local.security_group_ids
    subnets             = local.subnet_ids
  }
}

resource "aws_batch_job_queue" "batch" {
  name     = "${var.name_prefix}-queue"
  state    = "ENABLED"
  priority = 1
  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.batch.arn
  }
}

resource "aws_batch_job_definition" "runner" {
  name                  = "${var.name_prefix}-runner"
  type                  = "container"
  platform_capabilities = [local.is_fargate ? "FARGATE" : "EC2"]

  retry_strategy {
    attempts = 2 # chunk re-runs are idempotent (ingester skips completed dps)
  }

  container_properties = jsonencode(merge(
    {
      image      = "${aws_ecr_repository.runner.repository_url}:${var.runner_image_tag}"
      jobRoleArn = local.task_role_arn
      resourceRequirements = [
        { type = "VCPU", value = "1" },
        { type = "MEMORY", value = tostring(var.container_memory_mb) }
      ]
      environment = [
        # BATCH_S3_URI is supplied per-run via submit-time container overrides
        { name = "BATCH_S3_URI", value = "" }
      ]
    },
    jsondecode(local.is_fargate ? jsonencode({
      executionRoleArn = local.execution_role_arn
      fargatePlatformConfiguration = {
        platformVersion = "LATEST"
      }
      networkConfiguration = {
        assignPublicIp = "ENABLED"
      }
    }) : "{}")
  ))
}

# -------------------------------------------------------------------- outputs

output "bucket_name" {
  value = aws_s3_bucket.batch.bucket
}

output "ecr_repository_url" {
  value = aws_ecr_repository.runner.repository_url
}

output "job_queue" {
  value = aws_batch_job_queue.batch.name
}

output "job_definition" {
  value = aws_batch_job_definition.runner.name
}

output "region" {
  value = var.region
}
