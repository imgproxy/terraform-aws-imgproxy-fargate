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

run "rejects_invalid_cpu_architecture" {
  command = plan

  variables {
    cpu_architecture = "INVALID"
  }

  expect_failures = [var.cpu_architecture]
}

run "rejects_pro_without_registry_credentials" {
  command = plan

  variables {
    pro = true
  }

  expect_failures = [aws_ecs_cluster.main]
}

run "accepts_pro_with_custom_repo_without_credentials" {
  command = plan

  variables {
    pro  = true
    repo = "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy-pro"
  }

  assert {
    condition     = aws_ecs_cluster.main.name == "imgproxy"
    error_message = "pro with a custom repo must not require repo_credentials_secret"
  }
}

run "rejects_secure_mode_without_keys" {
  command = plan

  variables {
    keys_secret = null
  }

  # The common module repeats this check; mock it so only the root precondition is evaluated.
  override_module {
    target = module.imgproxy_common
    outputs = {
      image             = "mock"
      workers           = 1
      env_vars          = {}
      env_secret_vars   = {}
      cdn_cache_headers = []
      cdn_cache_cookies = []
    }
  }

  expect_failures = [aws_ecs_cluster.main]
}

run "rejects_secure_mode_without_salts" {
  command = plan

  variables {
    salts_secret = null
  }

  # The common module repeats this check; mock it so only the root precondition is evaluated.
  override_module {
    target = module.imgproxy_common
    outputs = {
      image             = "mock"
      workers           = 1
      env_vars          = {}
      env_secret_vars   = {}
      cdn_cache_headers = []
      cdn_cache_cookies = []
    }
  }

  expect_failures = [aws_ecs_cluster.main]
}

run "rejects_cloudfront_without_alb" {
  command = plan

  variables {
    enable_cloudfront = true
    create_alb        = false
  }

  expect_failures = [aws_ecs_cluster.main]
}

run "rejects_cloudfront_domains_without_certificate" {
  command = plan

  variables {
    enable_cloudfront  = true
    cloudfront_domains = ["cdn.example.com"]
  }

  expect_failures = [aws_ecs_cluster.main]
}

run "rejects_monitoring_with_insufficient_memory" {
  command = plan

  variables {
    enable_monitoring = true
    memory            = "256Mi"
  }

  expect_failures = [aws_ecs_cluster.main]
}

run "rejects_authorization_token_with_cloudfront" {
  command = plan

  variables {
    enable_cloudfront = true
    secret_secret = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy/secret"
    }
  }

  expect_failures = [aws_ecs_cluster.main]
}
