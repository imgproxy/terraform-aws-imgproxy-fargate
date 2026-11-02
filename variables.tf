# ── Basic Configuration ───────────────────────────────────────────────────────

variable "service_name" {
  type        = string
  default     = "imgproxy"
  description = "Prefix applied to every resource name."
}

variable "tag" {
  type        = string
  default     = "v4"
  description = "imgproxy image tag (version)."
}

variable "repo" {
  type        = string
  default     = null
  description = "Container repository to pull imgproxy from, without tag (e.g. 'registry.example.com/imgproxy' or '123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy'). When null, 'pro' selects docker.imgproxy.pro/imgproxy or ghcr.io/imgproxy/imgproxy. ECR repositories in the same account are pulled with the execution role and need no credentials; for any other private registry set repo_credentials_secret."
}

variable "repo_credentials_secret" {
  type = object({
    arn = string
  })
  default     = null
  description = "Secrets Manager secret with the credentials for the registry in 'repo' (or docker.imgproxy.pro when 'repo' is not set). Must be a JSON secret with 'username' and 'password' keys (ECS repositoryCredentials). Required when pro = true and repo is not set; the execution role is granted read access to it."
}

variable "environment" {
  type        = map(string)
  default     = {}
  description = "Additional environment variables passed to imgproxy (e.g. IMGPROXY_MAX_SRC_RESOLUTION)."
}

variable "secrets" {
  type = map(object({
    arn     = string
    version = optional(string, "")
  }))
  default     = {}
  description = "Map of environment variable names to Secrets Manager ARNs. Example: {IMGPROXY_NEW_RELIC_KEY = {arn = \"arn:aws:secretsmanager:us-east-1:123:secret:newrelic-key\"}}."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all created resources."
}

# ── Security & Signing ────────────────────────────────────────────────────────

variable "insecure" {
  type        = bool
  default     = false
  description = "Disable URL signature checks. When true, key and salt are not required."
}

variable "keys_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for imgproxy signing keys (comma-separated hex-encoded values). Required when insecure = false. Generate: openssl rand -hex 64. Sets IMGPROXY_KEY."
}

variable "salts_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for imgproxy signing salts (must match number of keys). Required when insecure = false. Sets IMGPROXY_SALT."
}

variable "secret_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for the authorization token. When set, requests must include Authorization: Bearer <token>. Sets IMGPROXY_SECRET."
}

variable "signature_size" {
  type        = number
  default     = 32
  description = "Number of bytes from the key/salt used for signing. Sets IMGPROXY_SIGNATURE_SIZE."
}

variable "trusted_signatures_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for trusted signature prefixes. imgproxy Pro only. Sets IMGPROXY_TRUSTED_SIGNATURES."
}

variable "source_url_encryption_key_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for the source URL encryption key. Sets IMGPROXY_SOURCE_URL_ENCRYPTION_KEY."
}

# ── Compute Resources ─────────────────────────────────────────────────────────

variable "cpu_architecture" {
  type        = string
  default     = "ARM64"
  description = "CPU architecture for the Fargate task. ARM64 (Graviton) is recommended — lower cost, same performance. Must match the image platform."
  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture must be ARM64 or X86_64."
  }
}

variable "spot_percentage" {
  type        = number
  default     = 0
  description = "Percentage of tasks to run on FARGATE_SPOT (0–99). At 0, only FARGATE is used. At 1–99, both providers are used with weights proportional to the percentage. Must be less than 100."

  validation {
    condition     = var.spot_percentage >= 0 && var.spot_percentage < 100
    error_message = "spot_percentage must be between 0 and 99 (inclusive)."
  }
}

variable "cpu" {
  type        = number
  default     = 1
  description = "vCPUs allocated to the imgproxy task (0.25, 0.5, 1, 2, 4, 8, 16). Fargate maps this to CPU units (cpu × 1024). Sets IMGPROXY_WORKERS default."
}

variable "memory" {
  type        = string
  default     = "2048Mi"
  description = "Memory limit for the Fargate task. Accepts Mi or Gi suffix (e.g. '2048Mi', '4Gi'). Must satisfy Fargate CPU/memory constraints: 1 vCPU requires 2–8 GB, 2 vCPU requires 4–16 GB."
}

variable "workers" {
  type        = number
  default     = null
  description = "Number of concurrent requests per container. Sets IMGPROXY_WORKERS. Defaults to cpu × 2."
}

variable "timeout" {
  type        = number
  default     = null
  description = "Request timeout in seconds. Sets IMGPROXY_TIMEOUT."
}

# ── Storage Integration ───────────────────────────────────────────────────────

variable "source_buckets" {
  type        = list(string)
  default     = []
  description = "S3 bucket names for imgproxy source images. The task role is granted s3:GetObject on each. Enables IMGPROXY_USE_S3."
}

variable "cache_bucket" {
  type        = string
  default     = null
  description = "S3 bucket name for imgproxy result cache (imgproxy Pro only). The task role is granted full object access."
}

# ── Scaling ───────────────────────────────────────────────────────────────────

variable "desired_count" {
  type        = number
  default     = null
  description = "Desired number of ECS tasks. Defaults to task_min_count. Changes after initial creation are ignored (managed by ECS auto-scaling)."
}

variable "task_min_count" {
  type        = number
  default     = 2
  description = "Minimum number of ECS tasks for Application Auto Scaling."
}

variable "task_max_count" {
  type        = number
  default     = 10
  description = "Maximum number of ECS tasks for Application Auto Scaling."
}

variable "deployment_minimum_healthy_percent" {
  type        = number
  default     = 100
  description = "Minimum percentage of healthy tasks during a rolling deployment. 100 = zero-downtime (new task starts before old stops). 0 = fastest deploy (brief outage). With task_min_count = 1, a value of 50 allows a zero-task gap."
  validation {
    condition     = var.deployment_minimum_healthy_percent >= 0 && var.deployment_minimum_healthy_percent <= 100
    error_message = "deployment_minimum_healthy_percent must be between 0 and 100."
  }
}

# ── imgproxy Pro ──────────────────────────────────────────────────────────────

variable "pro" {
  type        = bool
  default     = false
  description = "Use imgproxy Pro (docker.imgproxy.pro) instead of the community image (ghcr.io) as the default repo. Has no effect when repo is set."
}

variable "pro_license_key_secret" {
  type = object({
    arn     = string
    version = optional(string, "")
  })
  default     = null
  description = "Secrets Manager ARN for the imgproxy Pro license key. Sets IMGPROXY_LICENSE_KEY."
}

# ── Observability & Monitoring ────────────────────────────────────────────────

variable "enable_monitoring" {
  type        = bool
  default     = false
  description = "Enable the AWS Distro for OpenTelemetry (ADOT) sidecar container to export traces to X-Ray and metrics/logs to CloudWatch. Automatically configures imgproxy OTEL environment variables."
}

variable "otel_collector_config" {
  type        = string
  default     = null
  description = "OpenTelemetry Collector configuration YAML passed to the ADOT sidecar via AOT_CONFIG_CONTENT. When null, a default config exporting to X-Ray and CloudWatch is used."
}

variable "log_retention_days" {
  type        = number
  default     = 365
  description = "CloudWatch log group retention in days."
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "vpc_id" {
  type        = string
  description = "VPC ID to deploy the ECS service and ALB into."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet IDs for Fargate tasks. Use public subnets with assign_public_ip = true, or private subnets with a NAT gateway."
}

variable "alb_subnet_ids" {
  type        = list(string)
  default     = null
  description = "Subnet IDs for the Application Load Balancer. When null, uses subnet_ids. Set to public subnets when tasks are in private subnets."
}

variable "internal_alb" {
  type        = bool
  default     = false
  description = "Create an internal (non-internet-facing) ALB. Use for private deployments accessed via VPC only."
}

variable "assign_public_ip" {
  type        = bool
  default     = true
  description = "Assign a public IP to Fargate tasks. Required in public subnets to pull container images from public registries. Set to false when using private subnets with a NAT gateway."
}

variable "additional_security_group_ids" {
  type        = list(string)
  default     = []
  description = "Additional security group IDs to attach to Fargate tasks."
}

# ── Load Balancer ─────────────────────────────────────────────────────────────

variable "create_alb" {
  type        = bool
  default     = true
  description = "Create an Application Load Balancer for the ECS service."
}

variable "alb_certificate_arns" {
  type        = list(string)
  default     = []
  description = "ACM certificate ARNs for the HTTPS listener. When non-empty, creates a port 443 HTTPS listener. The first ARN is the primary certificate; additional ARNs are attached as SNI extras."
}

variable "alb_redirect_http_to_https" {
  type        = bool
  default     = true
  description = "Redirect HTTP to HTTPS on the ALB. Requires alb_certificate_arns to be set."
}

variable "alb_idle_timeout" {
  type        = number
  default     = 60
  description = "ALB connection idle timeout in seconds."
}

variable "alb_deregistration_delay" {
  type        = number
  default     = 300
  description = "Seconds the ALB waits before deregistering a target during deployments and scale-in. Must be >= alb_idle_timeout to avoid in-flight connection resets."
}

variable "alb_deletion_protection" {
  type        = bool
  default     = false
  description = "Enable deletion protection on the ALB."
}

variable "allow_public_access" {
  type        = bool
  default     = true
  description = "Allow public internet access to the ALB (0.0.0.0/0 on port 80/443)."
}

# ── CloudFront CDN ────────────────────────────────────────────────────────────

variable "enable_cloudfront" {
  type        = bool
  default     = false
  description = "Create a CloudFront distribution in front of the ALB for global edge caching. Requires create_alb = true."
}

variable "cloudfront_certificate_arn" {
  type        = string
  default     = null
  description = "ACM certificate ARN for CloudFront (must be in us-east-1). Required when cloudfront_domains is set."
}

variable "cloudfront_domains" {
  type        = list(string)
  default     = []
  description = "Custom domain aliases for the CloudFront distribution. Requires cloudfront_certificate_arn."
}

variable "cloudfront_origin_shield_region" {
  type        = string
  default     = null
  description = "AWS region to enable CloudFront Origin Shield (e.g. \"us-east-1\"). Adds an extra caching tier between edge locations and the ALB, reducing origin load. When null, Origin Shield is disabled."
}

variable "cdn_default_ttl" {
  type        = number
  default     = 31536000
  description = "Default CloudFront TTL in seconds. Set to 0 to let CloudFront respect origin Cache-Control headers."
}

variable "cdn_min_ttl" {
  type        = number
  default     = 0
  description = "Minimum CloudFront TTL in seconds. Set to a positive value to force a floor TTL regardless of origin headers."
}

variable "cdn_max_ttl" {
  type        = number
  default     = 31556926
  description = "Maximum CloudFront TTL in seconds, regardless of origin headers."
}

variable "cdn_redirect_http_to_https" {
  type        = bool
  default     = true
  description = "Redirect HTTP to HTTPS at the CloudFront level."
}

variable "cdn_waf_web_acl_id" {
  type        = string
  default     = null
  description = "WAF Web ACL ARN to associate with the CloudFront distribution."
}

# ── IAM ───────────────────────────────────────────────────────────────────────

variable "task_role_arn" {
  type        = string
  default     = null
  description = "ARN of an existing IAM role to use as the ECS task role. When null, a role is created with S3 and monitoring permissions as needed."
}

variable "execution_role_arn" {
  type        = string
  default     = null
  description = "ARN of an existing IAM role to use as the ECS task execution role. When null, a role is created with ECR pull and Secrets Manager access."
}
