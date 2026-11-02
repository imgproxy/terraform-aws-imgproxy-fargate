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

module "imgproxy" {
  source  = "imgproxy/imgproxy-fargate/aws"
  version = "~> 0.1"

  service_name = "imgproxy-insecure"
  tag          = "v4"

  vpc_id     = data.aws_vpc.default.id
  subnet_ids = data.aws_subnets.default.ids

  # Fargate Spot: 70% of the tasks run on Spot capacity, which is up to 70% cheaper.
  # One task always stays on regular Fargate, and imgproxy is stateless, so an
  # interrupted Spot task is simply replaced.
  spot_percentage = 70

  # WARNING: Insecure mode - no request signing
  # Use only for development/testing
  insecure = true
}

output "url" {
  description = "The URL of the deployed imgproxy service"
  value       = module.imgproxy.url
}

output "warning" {
  description = "Security warning"
  value       = "⚠️  This deployment runs in INSECURE mode with no request signing. Do not use in production!"
}
