data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  # Image repository: `repo` when set, otherwise the default selected by `pro`
  image_repo = var.repo != null ? var.repo : (var.pro ? "docker.imgproxy.pro/imgproxy" : "ghcr.io/imgproxy/imgproxy")
}

module "imgproxy_common" {
  source = "./modules/imgproxy-common"

  tag  = var.tag
  repo = local.image_repo

  cpu            = var.cpu
  workers        = var.workers
  timeout        = var.timeout
  signature_size = var.signature_size

  secret_key_name   = "arn"
  storage_env_key   = "IMGPROXY_USE_S3"
  storage_enabled   = length(var.source_buckets) > 0
  enable_monitoring = var.enable_monitoring
  otel_service_name = var.service_name

  insecure    = var.insecure
  environment = var.environment
  secrets     = { for k, v in var.secrets : k => { id = v.arn, version = v.version } }

  keys_secret                      = var.keys_secret != null ? { id = var.keys_secret.arn, version = var.keys_secret.version } : null
  salts_secret                     = var.salts_secret != null ? { id = var.salts_secret.arn, version = var.salts_secret.version } : null
  secret_secret                    = var.secret_secret != null ? { id = var.secret_secret.arn, version = var.secret_secret.version } : null
  trusted_signatures_secret        = var.trusted_signatures_secret != null ? { id = var.trusted_signatures_secret.arn, version = var.trusted_signatures_secret.version } : null
  source_url_encryption_key_secret = var.source_url_encryption_key_secret != null ? { id = var.source_url_encryption_key_secret.arn, version = var.source_url_encryption_key_secret.version } : null
  pro_license_key_secret           = var.pro_license_key_secret != null ? { id = var.pro_license_key_secret.arn, version = var.pro_license_key_secret.version } : null
}

locals {
  image           = module.imgproxy_common.image
  env_vars        = module.imgproxy_common.env_vars
  env_secret_vars = module.imgproxy_common.env_secret_vars

  cloudwatch_env_vars = {
    IMGPROXY_CLOUD_WATCH_SERVICE_NAME = var.service_name
    IMGPROXY_CLOUD_WATCH_NAMESPACE    = "imgproxy"
    IMGPROXY_CLOUD_WATCH_REGION       = data.aws_region.current.name
  }

  memory_mb      = endswith(var.memory, "Gi") ? tonumber(trimsuffix(var.memory, "Gi")) * 1024 : tonumber(trimsuffix(var.memory, "Mi"))
  cpu_units      = var.cpu * 1024
  desired_count  = coalesce(var.desired_count, var.task_min_count)
  otel_memory_mb = var.enable_monitoring ? 256 : 0

  secret_arns = distinct(compact(concat(
    [for k, v in local.env_secret_vars : v["arn"]],
    var.repo_credentials_secret != null ? [var.repo_credentials_secret.arn] : []
  )))

  ecs_secrets = [for k, v in local.env_secret_vars : {
    name      = k
    valueFrom = v["version"] != "" ? "${v["arn"]}:::${v["version"]}" : v["arn"]
  }]

  use_spot       = var.spot_percentage > 0
  fargate_weight = 100 - var.spot_percentage
  spot_weight    = var.spot_percentage
}

module "aws_common" {
  source = "./modules/aws-common"

  service_name = var.service_name
  tags         = var.tags

  execution_role_arn = var.execution_role_arn
  task_role_arn      = var.task_role_arn
  source_buckets     = var.source_buckets
  cache_bucket       = var.cache_bucket
  enable_monitoring  = var.enable_monitoring
  secret_arns        = local.secret_arns
  log_retention_days = var.log_retention_days

  vpc_id         = var.vpc_id
  subnet_ids     = var.subnet_ids
  alb_subnet_ids = var.alb_subnet_ids

  create_alb                 = var.create_alb
  alb_target_type            = "ip"
  internal_alb               = var.internal_alb
  allow_public_access        = var.allow_public_access
  alb_certificate_arns       = var.alb_certificate_arns
  alb_redirect_http_to_https = var.alb_redirect_http_to_https
  alb_idle_timeout           = var.alb_idle_timeout
  alb_deregistration_delay   = var.alb_deregistration_delay
  alb_deletion_protection    = var.alb_deletion_protection

  enable_cloudfront               = var.enable_cloudfront
  cloudfront_certificate_arn      = var.cloudfront_certificate_arn
  cloudfront_domains              = var.cloudfront_domains
  cloudfront_origin_shield_region = var.cloudfront_origin_shield_region
  cdn_default_ttl                 = var.cdn_default_ttl
  cdn_min_ttl                     = var.cdn_min_ttl
  cdn_max_ttl                     = var.cdn_max_ttl
  cdn_redirect_http_to_https      = var.cdn_redirect_http_to_https
  cdn_waf_web_acl_id              = var.cdn_waf_web_acl_id
  cdn_cache_headers               = module.imgproxy_common.cdn_cache_headers
  cdn_cache_cookies               = module.imgproxy_common.cdn_cache_cookies
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = var.service_name

  setting {
    name  = "containerInsights"
    value = var.enable_monitoring ? "enabled" : "disabled"
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = !var.pro || var.repo != null || var.repo_credentials_secret != null
      error_message = "repo_credentials_secret is required when pro = true and repo is not set."
    }
    precondition {
      condition     = var.insecure || (var.keys_secret != null && var.salts_secret != null)
      error_message = "keys_secret and salts_secret are required when insecure = false."
    }
    precondition {
      condition     = !var.enable_monitoring || local.memory_mb > 256
      error_message = "memory must be greater than 256Mi when enable_monitoring = true (256Mi is reserved for the OTEL sidecar)."
    }
    precondition {
      condition     = !var.enable_cloudfront || var.create_alb
      error_message = "create_alb must be true when enable_cloudfront = true."
    }
    precondition {
      condition     = !var.enable_cloudfront || var.secret_secret == null
      error_message = "secret_secret cannot be used with enable_cloudfront = true. CloudFront does not forward the Authorization header."
    }
    precondition {
      condition     = length(var.cloudfront_domains) == 0 || var.cloudfront_certificate_arn != null
      error_message = "cloudfront_certificate_arn is required when cloudfront_domains is set."
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = local.use_spot ? ["FARGATE", "FARGATE_SPOT"] : ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = local.fargate_weight
    base              = 1
  }

  dynamic "default_capacity_provider_strategy" {
    for_each = local.use_spot ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = local.spot_weight
      base              = 0
    }
  }
}

# ── ECS Task Definition ───────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "main" {
  family                   = var.service_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(local.cpu_units)
  memory                   = tostring(local.memory_mb)
  task_role_arn            = module.aws_common.task_role_arn
  execution_role_arn       = module.aws_common.execution_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode(concat(
    [merge(
      {
        name        = "imgproxy"
        image       = local.image
        essential   = true
        stopTimeout = 60

        portMappings = [{
          containerPort = 8080
          protocol      = "tcp"
        }]

        environment = [for k, v in merge(local.env_vars, local.cloudwatch_env_vars) : { name = k, value = v }]
        secrets     = local.ecs_secrets

        healthCheck = {
          command     = ["CMD-SHELL", "imgproxy health"]
          interval    = 10
          timeout     = 2
          retries     = 3
          startPeriod = 5
        }

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            "awslogs-group"         = module.aws_common.log_group_name
            "awslogs-region"        = data.aws_region.current.name
            "awslogs-stream-prefix" = "imgproxy"
          }
        }
      },
      var.repo_credentials_secret != null ? {
        repositoryCredentials = {
          credentialsParameter = var.repo_credentials_secret.arn
        }
      } : {}
    )],
    var.enable_monitoring ? [{
      name      = "otel-collector"
      image     = "public.ecr.aws/aws-observability/aws-otel-collector:v0.44.0"
      essential = false
      cpu       = 256
      memory    = local.otel_memory_mb

      environment = var.otel_collector_config != null ? [{
        name  = "AOT_CONFIG_CONTENT"
        value = var.otel_collector_config
      }] : []

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = module.aws_common.log_group_name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "otel"
        }
      }
    }] : []
  ))

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# ── Security Groups ───────────────────────────────────────────────────────────

# In awsvpc mode, tasks get their own ENI and the ALB connects directly to port 8080.
resource "aws_security_group" "tasks" {
  name_prefix = "${var.service_name}-tasks-"
  vpc_id      = var.vpc_id
  description = "${var.service_name} Fargate tasks"

  dynamic "ingress" {
    for_each = var.create_alb ? [1] : []
    content {
      from_port       = 8080
      to_port         = 8080
      protocol        = "tcp"
      security_groups = [module.aws_common.alb_sg_id]
      description     = "ALB to task"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.service_name}-tasks" })

  lifecycle {
    create_before_destroy = true
  }
}

# ── ECS Service ───────────────────────────────────────────────────────────────

resource "aws_ecs_service" "main" {
  name                              = var.service_name
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.main.arn
  desired_count                     = local.desired_count
  health_check_grace_period_seconds = var.create_alb ? 20 : 0

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = local.fargate_weight
    base              = 1
  }

  dynamic "capacity_provider_strategy" {
    for_each = local.use_spot ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = local.spot_weight
      base              = 0
    }
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = concat([aws_security_group.tasks.id], var.additional_security_group_ids)
    assign_public_ip = var.assign_public_ip
  }

  dynamic "load_balancer" {
    for_each = var.create_alb ? [1] : []
    content {
      target_group_arn = module.aws_common.target_group_arn
      container_name   = "imgproxy"
      container_port   = 8080
    }
  }

  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [module.aws_common]
}

# ── ECS Task Auto Scaling ─────────────────────────────────────────────────────
# Scales ECS task count based on imgproxy's WorkersUtilization CloudWatch metric.
# imgproxy publishes this metric via IMGPROXY_CLOUD_WATCH_* env vars (always set above).
# Fargate uses shorter cooldowns than EC2 because tasks start in ~30s vs ~3–5 min.

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.task_max_count
  min_capacity       = var.task_min_count
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.main]
}

resource "aws_appautoscaling_policy" "scale_out" {
  name               = "${var.service_name}-scale-out"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  step_scaling_policy_configuration {
    adjustment_type          = "PercentChangeInCapacity"
    cooldown                 = 30
    metric_aggregation_type  = "Average"
    min_adjustment_magnitude = 1

    step_adjustment {
      metric_interval_lower_bound = 0
      metric_interval_upper_bound = 25
      scaling_adjustment          = 20
    }
    step_adjustment {
      metric_interval_lower_bound = 25
      metric_interval_upper_bound = 50
      scaling_adjustment          = 40
    }
    step_adjustment {
      metric_interval_lower_bound = 50
      metric_interval_upper_bound = 75
      scaling_adjustment          = 60
    }
    step_adjustment {
      metric_interval_lower_bound = 75
      metric_interval_upper_bound = 100
      scaling_adjustment          = 80
    }
    step_adjustment {
      metric_interval_lower_bound = 100
      scaling_adjustment          = 100
    }
  }
}

resource "aws_appautoscaling_policy" "scale_in" {
  name               = "${var.service_name}-scale-in"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  step_scaling_policy_configuration {
    adjustment_type          = "PercentChangeInCapacity"
    cooldown                 = 600
    metric_aggregation_type  = "Average"
    min_adjustment_magnitude = 1

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -10
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "concurrency_high" {
  alarm_name          = "${var.service_name}-high-concurrency"
  alarm_description   = "Scale out ${var.service_name}: WorkersUtilization > 80%"
  metric_name         = "WorkersUtilization"
  namespace           = "imgproxy"
  statistic           = "Average"
  period              = 10
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ServiceName = var.service_name
  }

  alarm_actions = [aws_appautoscaling_policy.scale_out.arn]
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "concurrency_low" {
  alarm_name          = "${var.service_name}-low-concurrency"
  alarm_description   = "Scale in ${var.service_name}: WorkersUtilization < 50%"
  metric_name         = "WorkersUtilization"
  namespace           = "imgproxy"
  statistic           = "Average"
  period              = 30
  evaluation_periods  = 20
  threshold           = 50
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ServiceName = var.service_name
  }

  alarm_actions = [aws_appautoscaling_policy.scale_in.arn]
  tags          = var.tags
}
