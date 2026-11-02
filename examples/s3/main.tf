terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

# The default VPC only has public subnets: fine for trying the module out.
# For production, run the tasks in private subnets (see the signed example).
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_secretsmanager_secret" "keys" {
  name = "imgproxy-keys"
}

data "aws_secretsmanager_secret" "salts" {
  name = "imgproxy-salts"
}

module "imgproxy" {
  source  = "imgproxy/imgproxy-fargate/aws"
  version = "~> 0.1"

  service_name = "imgproxy"
  tag          = "v4"

  keys_secret = {
    arn = data.aws_secretsmanager_secret.keys.arn
  }
  salts_secret = {
    arn = data.aws_secretsmanager_secret.salts.arn
  }

  # Fargate Spot: 70% of the tasks run on Spot capacity (up to 70% cheaper). One task always
  # stays on regular Fargate, and imgproxy is stateless, so an interrupted task is replaced.
  spot_percentage = 70

  vpc_id     = data.aws_vpc.default.id
  subnet_ids = data.aws_subnets.default.ids

  # Existing bucket (see README): grants read access and enables the s3:// URL scheme
  source_buckets = ["${data.aws_caller_identity.current.account_id}-imgproxy-images"]

  environment = {
    # The region the bucket lives in
    IMGPROXY_S3_REGION = var.region
  }
}

output "url" {
  value = module.imgproxy.url
}
