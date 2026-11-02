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

# The default VPC only has public subnets, so this example runs in it to stay self-contained.
# For production, use your own VPC with private subnets: see "Private subnets" in the README
# and the commented-out settings in the module block below.
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

  # Request signing (required for production)
  keys_secret = {
    arn = data.aws_secretsmanager_secret.keys.arn
  }
  salts_secret = {
    arn = data.aws_secretsmanager_secret.salts.arn
  }

  # Fargate Spot: 70% of the tasks run on Spot capacity (up to 70% cheaper). One task always
  # stays on regular Fargate, and imgproxy is stateless, so an interrupted task is replaced.
  spot_percentage = 70

  # Networking: tasks in public subnets of the default VPC, with public IPs
  vpc_id     = data.aws_vpc.default.id
  subnet_ids = data.aws_subnets.default.ids

  # Production: run the tasks in private subnets and keep only the load balancer public.
  # The private subnets need a route to a NAT gateway (the tasks pull the image and fetch
  # source images from the internet); see "Private subnets" in the README.
  # vpc_id           = "vpc-0123456789abcdef0"
  # subnet_ids       = ["subnet-0aaa...", "subnet-0bbb..."] # private: the tasks
  # alb_subnet_ids   = ["subnet-0ccc...", "subnet-0ddd..."] # public: the internet-facing ALB
  # assign_public_ip = false
}

output "url" {
  value = module.imgproxy.url
}
