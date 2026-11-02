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

  enable_cloudfront = true

  # With a domain, CloudFront serves it over HTTPS using an ACM certificate issued in us-east-1:
  # cloudfront_domains         = ["cdn.example.com"]
  # cloudfront_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/..."

  cdn_default_ttl = 3600
  cdn_max_ttl     = 86400
}

output "url" {
  value = module.imgproxy.url
}

output "cloudfront_domain_name" {
  value       = module.imgproxy.cloudfront_domain_name
  description = "CloudFront domain. Point a CNAME (or a Route 53 alias) for your own domain at it"
}

output "cloudfront_hosted_zone_id" {
  value       = module.imgproxy.cloudfront_hosted_zone_id
  description = "CloudFront hosted zone ID, for Route 53 alias records"
}
