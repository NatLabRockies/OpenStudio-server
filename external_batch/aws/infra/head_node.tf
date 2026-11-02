# ---------------------------------------------------------------- head node
# Optional EC2 head node hosting OpenStudio Server (mongod + Rails API/UI)
# coordinating AWS Batch simulations.

variable "enable_head_node" {
  description = "Whether to provision an EC2 head node running OpenStudio Server"
  type        = bool
  default     = false
}

variable "head_node_instance_type" {
  description = "Instance type for the EC2 head node (e.g. t3.large, c6i.xlarge)"
  type        = string
  default     = "t3.large"
}

variable "head_node_key_name" {
  description = "EC2 key pair name for SSH access to the head node (optional)"
  type        = string
  default     = ""
}

variable "head_node_allowed_cidrs" {
  description = "CIDR blocks allowed to access head node web UI (8080/3000) and SSH"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "existing_head_node_instance_profile_name" {
  description = "Existing IAM instance profile name for the head node when create_iam_and_security_group is false"
  type        = string
  default     = ""
}

variable "existing_head_node_security_group_ids" {
  description = "Existing security group IDs for the head node when create_iam_and_security_group is false"
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------- IAM (Head Node)

resource "aws_iam_role" "head_node" {
  count = var.enable_head_node && var.create_iam_and_security_group ? 1 : 0
  name  = "${var.name_prefix}-head-node-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "head_node_s3_batch" {
  count = var.enable_head_node && var.create_iam_and_security_group ? 1 : 0
  name  = "${var.name_prefix}-head-node-s3-batch"
  role  = aws_iam_role.head_node[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [aws_s3_bucket.batch.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = ["${aws_s3_bucket.batch.arn}/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "batch:SubmitJob",
          "batch:DescribeJobs",
          "batch:DescribeJobQueues",
          "batch:DescribeComputeEnvironments",
          "batch:DescribeJobDefinitions",
          "batch:ListJobs",
          "batch:TerminateJob",
          "batch:CancelJob"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "head_node" {
  count = var.enable_head_node && var.create_iam_and_security_group ? 1 : 0
  name  = "${var.name_prefix}-head-node-profile"
  role  = aws_iam_role.head_node[0].name
}

# -------------------------------------------------------- Security Group (Head Node)

resource "aws_security_group" "head_node" {
  count       = var.enable_head_node && var.create_iam_and_security_group ? 1 : 0
  name        = "${var.name_prefix}-head-node-sg"
  description = "OpenStudio Server head node security group (Web UI + SSH)"
  vpc_id      = local.vpc_id

  # OpenStudio Server Web UI
  ingress {
    description = "OpenStudio Server Web UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.head_node_allowed_cidrs
  }

  ingress {
    description = "Rails Puma / Alternate Web UI"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.head_node_allowed_cidrs
  }

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.head_node_allowed_cidrs
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ------------------------------------------------------------- AMI & EC2 Instance

data "aws_ami" "ubuntu" {
  count       = var.enable_head_node ? 1 : 0
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["099720109477"] # Canonical
}

locals {
  head_node_sg_ids = var.create_iam_and_security_group ? (
    var.enable_head_node ? [aws_security_group.head_node[0].id] : []
  ) : var.existing_head_node_security_group_ids

  head_node_profile = var.create_iam_and_security_group ? (
    var.enable_head_node ? aws_iam_instance_profile.head_node[0].name : null
  ) : (var.existing_head_node_instance_profile_name != "" ? var.existing_head_node_instance_profile_name : null)
}

resource "aws_instance" "head_node" {
  count                  = var.enable_head_node ? 1 : 0
  ami                    = data.aws_ami.ubuntu[0].id
  instance_type          = var.head_node_instance_type
  subnet_id              = local.subnet_ids[0]
  key_name               = var.head_node_key_name != "" ? var.head_node_key_name : null
  vpc_security_group_ids = local.head_node_sg_ids
  iam_instance_profile   = local.head_node_profile

  associate_public_ip_address = true

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = <<-EOF
              #!/bin/bash
              set -ex
              apt-get update -y
              apt-get install -y docker.io docker-compose git awscli curl
              systemctl enable --now docker
              usermod -aG docker ubuntu
              EOF

  tags = {
    Name = "${var.name_prefix}-head-node"
    Role = "OpenStudio-Server-Head-Node"
  }
}

# ------------------------------------------------------------- Head Node Outputs

output "head_node_id" {
  description = "EC2 Instance ID of the head node"
  value       = var.enable_head_node ? aws_instance.head_node[0].id : null
}

output "head_node_public_ip" {
  description = "Public IP address of the head node"
  value       = var.enable_head_node ? aws_instance.head_node[0].public_ip : null
}

output "head_node_ui_url" {
  description = "OpenStudio Server Web UI URL on the head node"
  value       = var.enable_head_node ? "http://${aws_instance.head_node[0].public_ip}:8080" : null
}
