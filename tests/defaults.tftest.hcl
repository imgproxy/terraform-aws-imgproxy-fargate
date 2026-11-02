mock_provider "aws" {}

variables {
  vpc_id     = "vpc-12345678"
  subnet_ids = ["subnet-aaa111", "subnet-bbb222"]
  keys_secret = {
    arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/keys"
    version = ""
  }
  salts_secret = {
    arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/salts"
    version = ""
  }
}

run "default_service_name" {
  command = plan

  assert {
    condition     = aws_ecs_cluster.main.name == "imgproxy"
    error_message = "ECS cluster name must equal service_name default"
  }

  assert {
    condition     = aws_ecs_service.main.name == "imgproxy"
    error_message = "ECS service name must equal service_name default"
  }

  assert {
    condition     = module.aws_common.log_group_name == "/aws/ecs/imgproxy"
    error_message = "Log group name must use default service_name"
  }
}

run "custom_service_name_propagates" {
  command = plan

  variables {
    service_name = "myapp"
  }

  assert {
    condition     = aws_ecs_cluster.main.name == "myapp"
    error_message = "ECS cluster name must reflect service_name"
  }

  assert {
    condition     = aws_ecs_service.main.name == "myapp"
    error_message = "ECS service name must reflect service_name"
  }

  assert {
    condition     = module.aws_common.log_group_name == "/aws/ecs/myapp"
    error_message = "Log group name must use service_name"
  }
}

run "fargate_network_mode" {
  command = plan

  assert {
    condition     = aws_ecs_task_definition.main.network_mode == "awsvpc"
    error_message = "Fargate task definition must use awsvpc network mode"
  }

  assert {
    condition     = contains(aws_ecs_task_definition.main.requires_compatibilities, "FARGATE")
    error_message = "Task definition must require FARGATE compatibility"
  }
}

run "fargate_capacity_provider_default" {
  command = plan

  assert {
    condition     = length([for s in aws_ecs_cluster_capacity_providers.main.default_capacity_provider_strategy : s if s.capacity_provider == "FARGATE"]) == 1
    error_message = "Default capacity provider must be FARGATE when spot_percentage = 0"
  }

  assert {
    condition     = length([for s in aws_ecs_cluster_capacity_providers.main.default_capacity_provider_strategy : s if s.capacity_provider == "FARGATE" && s.base == 1]) == 1
    error_message = "FARGATE capacity provider must have base = 1"
  }
}

run "fargate_spot_capacity_provider" {
  command = plan

  variables {
    spot_percentage = 70
  }

  assert {
    condition     = length([for s in aws_ecs_cluster_capacity_providers.main.default_capacity_provider_strategy : s if s.capacity_provider == "FARGATE_SPOT"]) == 1
    error_message = "FARGATE_SPOT must be in capacity providers when spot_percentage > 0"
  }

  assert {
    condition     = length([for s in aws_ecs_cluster_capacity_providers.main.default_capacity_provider_strategy : s if s.capacity_provider == "FARGATE" && s.base == 1]) == 1
    error_message = "FARGATE must keep base = 1 when spot_percentage > 0"
  }

  assert {
    condition     = length([for s in aws_ecs_cluster_capacity_providers.main.default_capacity_provider_strategy : s if s.capacity_provider == "FARGATE_SPOT" && s.weight == 70]) == 1
    error_message = "FARGATE_SPOT weight must equal spot_percentage"
  }

  assert {
    condition     = length([for s in aws_ecs_cluster_capacity_providers.main.default_capacity_provider_strategy : s if s.capacity_provider == "FARGATE" && s.weight == 30]) == 1
    error_message = "FARGATE weight must equal 100 - spot_percentage"
  }
}

run "alb_created_by_default" {
  command = plan

  assert {
    condition     = module.aws_common.alb_created == true
    error_message = "ALB must be created by default"
  }
}

run "alb_disabled" {
  command = plan

  variables {
    create_alb = false
  }

  assert {
    condition     = module.aws_common.alb_created == false
    error_message = "ALB must not be created when create_alb = false"
  }
}

run "cloudfront_disabled_by_default" {
  command = plan

  assert {
    condition     = module.aws_common.cloudfront_created == false
    error_message = "CloudFront must not be created by default"
  }
}

run "cloudfront_enabled" {
  command = plan

  variables {
    enable_cloudfront = true
  }

  assert {
    condition     = module.aws_common.cloudfront_created == true
    error_message = "CloudFront must be created when enable_cloudfront = true"
  }
}

run "monitoring_disabled_by_default" {
  command = plan

  assert {
    condition     = length([for s in aws_ecs_cluster.main.setting : s if s.name == "containerInsights" && s.value == "disabled"]) == 1
    error_message = "Container Insights must be disabled by default"
  }
}

run "monitoring_enables_container_insights" {
  command = plan

  variables {
    enable_monitoring = true
  }

  assert {
    condition     = length([for s in aws_ecs_cluster.main.setting : s if s.name == "containerInsights" && s.value == "enabled"]) == 1
    error_message = "Container Insights must be enabled when enable_monitoring = true"
  }
}

run "log_retention_default" {
  command = plan

  assert {
    condition     = module.aws_common.log_retention_days == 365
    error_message = "Log retention must default to 365 days"
  }
}

run "log_retention_custom" {
  command = plan

  variables {
    log_retention_days = 30
  }

  assert {
    condition     = module.aws_common.log_retention_days == 30
    error_message = "Log retention must reflect log_retention_days"
  }
}

run "task_min_count_default" {
  command = plan

  assert {
    condition     = aws_appautoscaling_target.ecs.min_capacity == 2
    error_message = "task_min_count must default to 2"
  }
}

run "scale_in_cooldown" {
  command = plan

  assert {
    condition     = aws_appautoscaling_policy.scale_in.step_scaling_policy_configuration[0].cooldown == 600
    error_message = "Scale-in cooldown must be 600 seconds"
  }

  assert {
    condition     = length(aws_appautoscaling_policy.scale_in.step_scaling_policy_configuration[0].step_adjustment) == 1
    error_message = "Scale-in must have exactly one step adjustment"
  }
}

run "monitoring_otel_sidecar" {
  command = plan

  variables {
    enable_monitoring = true
  }

  assert {
    condition     = length([for c in jsondecode(aws_ecs_task_definition.main.container_definitions) : c if c.name == "otel-collector"]) == 1
    error_message = "OTEL sidecar container must be present when enable_monitoring = true"
  }

  assert {
    condition = length([
      for c in jsondecode(aws_ecs_task_definition.main.container_definitions) : c
      if c.name == "otel-collector" && c.image == "public.ecr.aws/aws-observability/aws-otel-collector:v0.44.0"
    ]) == 1
    error_message = "OTEL sidecar must use the ADOT collector image"
  }

  assert {
    condition = length([
      for c in jsondecode(aws_ecs_task_definition.main.container_definitions) : c
      if c.name == "otel-collector" && !can(c.command)
    ]) == 1
    error_message = "OTEL sidecar must not override command when otel_collector_config is not set"
  }

  assert {
    condition = length([
      for c in jsondecode(aws_ecs_task_definition.main.container_definitions) : c
      if c.name == "otel-collector" && length(c.environment) == 0
    ]) == 1
    error_message = "OTEL sidecar environment must be empty when otel_collector_config is not set"
  }
}

run "monitoring_custom_otel_config" {
  command = plan

  variables {
    enable_monitoring     = true
    otel_collector_config = "receivers:\n  otlp:\n    protocols:\n      grpc:\n"
  }

  assert {
    condition = length([
      for c in jsondecode(aws_ecs_task_definition.main.container_definitions) : c
      if c.name == "otel-collector" && length([for e in c.environment : e if e.name == "AOT_CONFIG_CONTENT"]) == 1
    ]) == 1
    error_message = "OTEL sidecar must set AOT_CONFIG_CONTENT when otel_collector_config is provided"
  }
}

run "monitoring_disabled_no_otel_sidecar" {
  command = plan

  assert {
    condition     = length([for c in jsondecode(aws_ecs_task_definition.main.container_definitions) : c if c.name == "otel-collector"]) == 0
    error_message = "OTEL sidecar must not be present when enable_monitoring = false"
  }
}

run "cdn_cache_policy_no_headers_by_default" {
  command = plan

  variables {
    enable_cloudfront = true
  }

  assert {
    condition     = module.aws_common.cloudfront_cache_policy_header_behavior == "none"
    error_message = "CloudFront header_behavior must be 'none' when no format-detection env vars are set"
  }

  assert {
    condition     = module.aws_common.cloudfront_cache_policy_cookie_behavior == "none"
    error_message = "CloudFront cookie_behavior must be 'none' by default"
  }
}

run "cdn_cache_policy_accept_on_format_detection" {
  command = plan

  variables {
    enable_cloudfront = true
    environment = {
      IMGPROXY_AUTO_WEBP = "true"
    }
  }

  assert {
    condition     = module.aws_common.cloudfront_cache_policy_header_behavior == "whitelist"
    error_message = "CloudFront header_behavior must be 'whitelist' when IMGPROXY_AUTO_WEBP is set"
  }

  assert {
    condition     = contains(toset(module.aws_common.cloudfront_cache_policy_headers), "Accept")
    error_message = "Accept header must be in the CloudFront cache key when IMGPROXY_AUTO_WEBP = true"
  }
}

run "cdn_cache_policy_client_hints" {
  command = plan

  variables {
    enable_cloudfront = true
    environment = {
      IMGPROXY_ENABLE_CLIENT_HINTS = "1"
    }
  }

  assert {
    condition = alltrue([
      for h in ["Sec-Ch-Dpr", "Dpr", "Sec-Ch-Width", "Width"] :
      contains(toset(module.aws_common.cloudfront_cache_policy_headers), h)
    ])
    error_message = "Client hints headers must be in the CloudFront cache key when IMGPROXY_ENABLE_CLIENT_HINTS = 1"
  }
}

run "cdn_cache_policy_custom_headers_and_cookies" {
  command = plan

  variables {
    enable_cloudfront = true
    environment = {
      IMGPROXY_CACHE_KEY_HEADERS = "X-Foo, X-Bar"
      IMGPROXY_CACHE_KEY_COOKIES = "session"
    }
  }

  assert {
    condition = alltrue([
      for h in ["X-Foo", "X-Bar"] :
      contains(toset(module.aws_common.cloudfront_cache_policy_headers), h)
    ])
    error_message = "IMGPROXY_CACHE_KEY_HEADERS values must appear in CloudFront headers whitelist"
  }

  assert {
    condition     = contains(toset(module.aws_common.cloudfront_cache_policy_cookies), "session")
    error_message = "IMGPROXY_CACHE_KEY_COOKIES values must appear in CloudFront cookies whitelist"
  }
}
