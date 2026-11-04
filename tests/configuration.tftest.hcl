mock_provider "aws" {}

variables {
  vpc_id     = "vpc-12345678"
  subnet_ids = ["subnet-aaa111", "subnet-bbb222"]

  # Most tests plan a plain HTTP ALB; the TLS requirement has its own runs in validation.tftest.hcl.
  allow_insecure_http = true

  keys_secret = {
    arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/keys"
    version = ""
  }
  salts_secret = {
    arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/salts"
    version = ""
  }
}

run "secure_mode_wires_signing_secrets" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_ecs_task_definition.main.container_definitions)[0].secrets : s
      if s.name == "IMGPROXY_KEY" && s.valueFrom == "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/keys"
    ]) == 1
    error_message = "IMGPROXY_KEY secret must be wired from keys_secret"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_ecs_task_definition.main.container_definitions)[0].secrets : s
      if s.name == "IMGPROXY_SALT" && s.valueFrom == "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/salts"
    ]) == 1
    error_message = "IMGPROXY_SALT secret must be wired from salts_secret"
  }
}

run "insecure_mode_skips_signing_secrets" {
  command = plan

  variables {
    insecure     = true
    keys_secret  = null
    salts_secret = null
  }

  assert {
    condition = length([
      for s in jsondecode(aws_ecs_task_definition.main.container_definitions)[0].secrets : s
      if s.name == "IMGPROXY_KEY" || s.name == "IMGPROXY_SALT"
    ]) == 0
    error_message = "No signing secrets should be wired when insecure = true"
  }
}

run "source_buckets_enables_use_s3_env" {
  command = plan

  variables {
    source_buckets = ["my-imgproxy-source"]
  }

  assert {
    condition = length([
      for e in jsondecode(aws_ecs_task_definition.main.container_definitions)[0].environment : e
      if e.name == "IMGPROXY_USE_S3" && e.value == "true"
    ]) == 1
    error_message = "IMGPROXY_USE_S3 must be set when source_buckets is non-empty"
  }
}

run "default_image_is_community" {
  command = plan

  assert {
    condition     = jsondecode(aws_ecs_task_definition.main.container_definitions)[0].image == "ghcr.io/imgproxy/imgproxy:v4"
    error_message = "The default image must be the community edition on ghcr.io"
  }

  assert {
    condition     = !contains(keys(jsondecode(aws_ecs_task_definition.main.container_definitions)[0]), "repositoryCredentials")
    error_message = "No registry credentials must be injected by default"
  }
}

run "pro_selects_default_pro_repo_and_injects_credentials" {
  command = plan

  variables {
    pro = true
    repo_credentials_secret = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/pro-registry"
    }
    pro_license_key_secret = {
      arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/pro-license"
      version = ""
    }
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.main.container_definitions)[0].image == "docker.imgproxy.pro/imgproxy:v4"
    error_message = "pro = true without repo must select docker.imgproxy.pro/imgproxy"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.main.container_definitions)[0].repositoryCredentials.credentialsParameter == "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/pro-registry"
    error_message = "Registry credentials must be injected into the imgproxy container definition"
  }
}

run "custom_repo_and_tag" {
  command = plan

  variables {
    repo = "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy-custom"
    tag  = "my-tag"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.main.container_definitions)[0].image == "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy-custom:my-tag"
    error_message = "repo and tag must form the image reference"
  }

  assert {
    condition     = !contains(keys(jsondecode(aws_ecs_task_definition.main.container_definitions)[0]), "repositoryCredentials")
    error_message = "A custom repo without repo_credentials_secret must not inject credentials (ECR is pulled with the execution role)"
  }
}

run "custom_repo_overrides_pro" {
  command = plan

  variables {
    pro  = true
    repo = "registry.example.com/imgproxy-custom"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.main.container_definitions)[0].image == "registry.example.com/imgproxy-custom:v4"
    error_message = "pro must have no effect on the image when repo is set"
  }
}

run "custom_private_repo_injects_credentials" {
  command = plan

  variables {
    repo = "registry.example.com/imgproxy-custom"
    repo_credentials_secret = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/registry"
    }
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.main.container_definitions)[0].repositoryCredentials.credentialsParameter == "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/registry"
    error_message = "repo_credentials_secret must be injected for a custom repo even when pro = false"
  }
}

run "tag_accepts_sha256_digest" {
  command = plan

  variables {
    tag = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.main.container_definitions)[0].image == "ghcr.io/imgproxy/imgproxy@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    error_message = "A sha256: tag must be referenced with @ instead of :"
  }
}

run "fargate_spot_configures_capacity_providers" {
  command = plan

  variables {
    spot_percentage = 40
  }

  assert {
    condition     = contains(toset(aws_ecs_cluster_capacity_providers.main.capacity_providers), "FARGATE_SPOT")
    error_message = "FARGATE_SPOT must be added to the cluster's capacity providers when spot_percentage > 0"
  }

  assert {
    condition = length([
      for s in aws_ecs_cluster_capacity_providers.main.default_capacity_provider_strategy : s
      if s.capacity_provider == "FARGATE_SPOT" && s.weight == 40
    ]) == 1
    error_message = "FARGATE_SPOT capacity provider strategy weight must equal spot_percentage"
  }

  assert {
    condition = length([
      for s in aws_ecs_cluster_capacity_providers.main.default_capacity_provider_strategy : s
      if s.capacity_provider == "FARGATE" && s.weight == 60
    ]) == 1
    error_message = "FARGATE capacity provider strategy weight must equal 100 - spot_percentage"
  }
}

run "tasks_have_no_public_ip_by_default" {
  command = plan

  assert {
    condition     = aws_ecs_service.main.network_configuration[0].assign_public_ip == false
    error_message = "Tasks must not get public IPs by default"
  }
}

run "assign_public_ip_opt_in" {
  command = plan

  variables {
    assign_public_ip = true
  }

  assert {
    condition     = aws_ecs_service.main.network_configuration[0].assign_public_ip == true
    error_message = "assign_public_ip = true must propagate to the ECS service network configuration"
  }
}

run "custom_task_role_skips_creation" {
  command = plan

  variables {
    task_role_arn = "arn:aws:iam::123456789012:role/custom-task-role"
  }

  assert {
    condition     = module.aws_common.task_role_arn == "arn:aws:iam::123456789012:role/custom-task-role"
    error_message = "task_role_arn output must reflect the provided ARN when task_role_arn is set"
  }
}

run "custom_execution_role_skips_creation" {
  command = plan

  variables {
    execution_role_arn = "arn:aws:iam::123456789012:role/custom-execution-role"
  }

  assert {
    condition     = module.aws_common.execution_role_arn == "arn:aws:iam::123456789012:role/custom-execution-role"
    error_message = "execution_role_arn output must reflect the provided ARN when execution_role_arn is set"
  }
}
