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

data "aws_secretsmanager_secret" "pro_license" {
  name = "imgproxy-pro-license"
}

data "aws_secretsmanager_secret" "pro_registry" {
  name = "imgproxy-pro-registry"
}

locals {
  cache_bucket = "${data.aws_caller_identity.current.account_id}-imgproxy-cache"
}

module "imgproxy" {
  source  = "imgproxy/imgproxy-fargate/aws"
  version = "~> 0.1"

  service_name = "imgproxy-pro"
  tag          = "v4"

  # pro selects docker.imgproxy.pro/imgproxy as the default repo. The credentials are a JSON
  # secret with "username" and "password" keys, which ECS uses to pull the image.
  pro = true
  repo_credentials_secret = {
    arn = data.aws_secretsmanager_secret.pro_registry.arn
  }
  pro_license_key_secret = {
    arn = data.aws_secretsmanager_secret.pro_license.arn
  }

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

  # Existing bucket (see README) for the processed-result cache (Pro)
  cache_bucket = local.cache_bucket

  environment = {
    IMGPROXY_CACHE_USE    = "s3"
    IMGPROXY_CACHE_BUCKET = local.cache_bucket
  }
}

output "url" {
  value = module.imgproxy.url
}
