# imgproxy Terraform Module for AWS ECS (Fargate)

Terraform module to deploy [imgproxy](https://imgproxy.net/) on AWS ECS with Fargate, behind an Application Load Balancer, with optional CloudFront CDN, OpenTelemetry-based monitoring, and S3 integration.

## Features

- **ECS on Fargate** with configurable CPU, memory and auto scaling, no EC2 instances or AMIs to manage
- **Fargate Spot** via `spot_percentage` to run part of the tasks on Spot capacity for up to 70% lower cost
- **Application Load Balancer** with HTTP/HTTPS listeners, ACM certificates and HTTP to HTTPS redirect
- **CloudFront CDN** for caching processed images at edge locations worldwide, with the load balancer locked to CloudFront
- **imgproxy Pro and private registries** via ECS `repositoryCredentials` with Secrets Manager
- **OpenTelemetry collector sidecar** (AWS Distro for OpenTelemetry) for traces to X-Ray and metrics and logs to CloudWatch
- **S3 bucket integration** for source images and result cache (Pro)
- **Request signing** with keys and salts from Secrets Manager
- **Private subnets** support: tasks without public IPs, with only the load balancer in public subnets
- **IAM provisioning** of the execution and task roles with least-privilege policies

## Usage

```hcl
module "imgproxy" {
  source  = "imgproxy/imgproxy-fargate/aws"
  version = "~> 0.1"

  service_name = "imgproxy"

  # Networking: tasks in private subnets, internet-facing ALB in public subnets
  vpc_id           = "vpc-0123456789abcdef0"
  subnet_ids       = ["subnet-0aaa...", "subnet-0bbb..."] # private: the tasks
  alb_subnet_ids   = ["subnet-0ccc...", "subnet-0ddd..."] # public: the ALB
  assign_public_ip = false

  keys_secret  = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy-keys-AbCdEf" }
  salts_secret = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy-salts-AbCdEf" }

  # Run part of the tasks on Fargate Spot to save cost
  spot_percentage = 70
}
```

## Prerequisites

- An AWS account with [sufficient permissions](example-permission-set.json) to create ECS, IAM, ALB, CloudFront and CloudWatch resources, and the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) authenticated.
- **An existing VPC with subnets.** The module does not create networking: see [Networking](#networking).
- Terraform >= 1.5.

## Examples

Start with [insecure](examples/insecure/) and follow the "Next" link at the end of each README; every step adds one feature.

- [insecure](examples/insecure/) - Minimal deployment without request signing (development only)
- [signed](examples/signed/) - Production setup with URL signing, including how to use private subnets
- [s3](examples/s3/) - Private S3 bucket as the image source
- [cdn](examples/cdn/) - CloudFront in front of the load balancer
- [pro](examples/pro/) - imgproxy Pro with license key and S3 result cache
- [complete](examples/complete/) - Full-featured deployment with Pro, monitoring, S3 and CloudFront

All examples run in the default VPC to stay self-contained, and use Fargate Spot.

## Notes

### Networking

The module needs an existing VPC and subnets. There are two layouts:

**Private subnets (recommended for production).** The tasks run in private subnets without public IPs, and only the load balancer is public:

```hcl
vpc_id           = "vpc-0123456789abcdef0"
subnet_ids       = ["subnet-0aaa...", "subnet-0bbb..."] # private: the tasks
alb_subnet_ids   = ["subnet-0ccc...", "subnet-0ddd..."] # public: the internet-facing ALB
assign_public_ip = false
```

- Set `alb_subnet_ids` to **public** subnets. When it is unset, the ALB is placed in `subnet_ids`, that is, in the private subnets, and is not reachable from the internet. For an ALB reachable only from inside the VPC, set `internal_alb = true` instead.
- Tasks without public IPs need an outbound route. imgproxy downloads source images from the internet and the task pulls its image from `ghcr.io` (or `docker.imgproxy.pro`), so the private subnets need a **NAT gateway**. Without one, tasks fail to start with `CannotPullContainerError`.
- If the source images only live in S3 and the image comes from ECR, VPC endpoints can replace the NAT gateway: an S3 gateway endpoint (free) plus interface endpoints for `ecr.api`, `ecr.dkr`, `secretsmanager` and `logs`.
- The task security group only accepts port 8080 from the ALB. Add rules for VPN or bastion access through the `tasks_security_group_id` output, or pass `additional_security_group_ids`.

**Public subnets (quick start).** Tasks in public subnets, such as those of the default VPC, need `assign_public_ip = true` (the default) to reach the registry, Secrets Manager and CloudWatch without a NAT gateway. This is meant for trying the module out, as every task is directly reachable by IP (still only on port 8080 from the ALB).

### Additional secrets

The `secrets` variable maps extra environment variables to Secrets Manager secrets, for integrations such as error tracking:

```hcl
secrets = {
  IMGPROXY_SENTRY_DSN  = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sentry-dsn-AbCdEf" }
  IMGPROXY_BUGSNAG_KEY = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:bugsnag-api-key-AbCdEf", version = "3" }
}
```

Names should match [imgproxy's configuration](https://docs.imgproxy.net/configuration). `version` is a Secrets Manager version ID; when it is omitted, the current version is used. When the module creates the execution role (no `execution_role_arn`), it is granted read access to every secret you pass.

### Image delivery

Fargate pulls the image directly, with no intermediate registry. When `repo` is not set it defaults to `ghcr.io/imgproxy/imgproxy` (Community) or, with `pro = true`, `docker.imgproxy.pro/imgproxy`.

To pull from your own image, set `repo` to the image without tag, plus `tag`:

```hcl
repo = "123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy-custom"
tag  = "my-tag"
```

`tag` also accepts a `sha256:` digest, which is referenced as `repo@sha256:...`.

- An **ECR** repository in your account needs no credentials: the execution role the module creates can pull from it. If you pass your own `execution_role_arn`, it needs the usual ECR pull permissions.
- For any other **private registry**, set `repo_credentials_secret` to a Secrets Manager secret holding JSON with `username` and `password` keys. ECS uses it as `repositoryCredentials`, and the execution role the module creates is granted read access to it (if you pass your own `execution_role_arn`, grant it `secretsmanager:GetSecretValue` on the secret yourself):

  ```hcl
  repo                    = "registry.example.com/imgproxy-custom"
  repo_credentials_secret = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:registry-AbCdEf" }
  tag                     = "my-tag"
  ```

- `pro = true` only selects the default `repo`. It has no effect when `repo` is set, and for docker.imgproxy.pro only `repo_credentials_secret` is required (a JSON secret with `username` `imgproxy` and your registry password).

The task runs on ARM64 (Graviton) by default (`cpu_architecture = "ARM64"`), so the image must support `linux/arm64`; set `cpu_architecture = "X86_64"` otherwise.

### Fargate Spot

`spot_percentage` (0-99) runs that share of the tasks on `FARGATE_SPOT`, which costs up to 70% less than regular Fargate. At `0` (the default) only regular Fargate is used.

```hcl
spot_percentage = 70 # FARGATE weight 30, FARGATE_SPOT weight 70
```

The capacity provider strategy keeps `base = 1` on regular Fargate, so one task is always on-demand and the service never depends on Spot capacity alone. Spot tasks can be reclaimed with a two-minute warning, and imgproxy is stateless, so ECS just starts a replacement. With `task_min_count = 1` the single task is the on-demand one, and Spot is only used when the service scales out.

### Scaling

The service scales between `task_min_count` and `task_max_count` with Application Auto Scaling, using step policies on imgproxy's `WorkersUtilization` CloudWatch metric (scale out above 80%, scale in below 50%). imgproxy publishes the metric through the `IMGPROXY_CLOUD_WATCH_*` variables the module always sets. Task count changes after the initial creation are ignored by Terraform.

### Monitoring

With `enable_monitoring = true`, an AWS Distro for OpenTelemetry collector sidecar receives OTLP data from imgproxy on `localhost:4318` and exports traces to X-Ray and metrics and logs to CloudWatch. The task role gets the matching X-Ray and CloudWatch permissions, and Container Insights is enabled on the cluster. The collector reserves 256Mi of the task memory. Pass your own collector configuration through `otel_collector_config`.

### S3 integration

The module grants IAM permissions on existing buckets and does not create them. `source_buckets` enables the `s3://` URL scheme; `cache_bucket` (Pro) is for processed results, configured via `environment`. imgproxy uses `IMGPROXY_S3_REGION` for the bucket region: set it through `environment` when the region is not the default one.

### CloudFront

With `enable_cloudfront = true`, a CloudFront distribution is created in front of the load balancer (`create_alb` must stay `true`). It serves the `*.cloudfront.net` domain over HTTPS, or your own domain through `cloudfront_domains` and a certificate issued in **us-east-1** (`cloudfront_certificate_arn`).

The load balancer is then locked to CloudFront: its security group admits only the CloudFront origin-facing IP ranges, and the listener returns `403` unless the request carries a secret `X-Origin-Verify` header that your distribution adds. The secret is generated by the module. Without `alb_certificate_arns`, CloudFront reaches the load balancer over plain HTTP; set them to use HTTPS to the origin too.

The cache key follows your imgproxy configuration (`Accept` with format detection, client hints, `IMGPROXY_CACHE_KEY_HEADERS` and `IMGPROXY_CACHE_KEY_COOKIES`). `secret_secret` cannot be combined with CloudFront, which does not forward the `Authorization` header.

### Private load balancer

```hcl
internal_alb = true
```

An internal load balancer has no public addresses and is only reachable from inside the VPC and from networks connected to it (peering, VPN, Direct Connect). Put `alb_subnet_ids` (or `subnet_ids`) on private subnets in that case.

### Health check and logs

The service exposes `/health` on port 8080. Logs go to the CloudWatch log group `/aws/ecs/<service_name>` (the `log_group_name` output), kept for `log_retention_days` days (365 by default).

### Vendored modules

`modules/aws-common` and `modules/imgproxy-common` are generated copies of the modules of the same name in `imgproxy/terraform-common`. Do not edit them here: change them upstream and run `sync.sh` from that repository.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.5 |
| aws | ~> 5.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 5.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| aws\_common | ./modules/aws-common | n/a |
| imgproxy\_common | ./modules/imgproxy-common | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_appautoscaling_policy.scale_in](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_policy.scale_out](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_target.ecs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_target) | resource |
| [aws_cloudwatch_metric_alarm.concurrency_high](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.concurrency_low](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_ecs_cluster.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster) | resource |
| [aws_ecs_cluster_capacity_providers.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster_capacity_providers) | resource |
| [aws_ecs_service.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service) | resource |
| [aws_ecs_task_definition.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition) | resource |
| [aws_security_group.tasks](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Required |
| ---- | ----------- | ---- | :------: |
| subnet\_ids | Subnet IDs for Fargate tasks. Use public subnets with assign\_public\_ip = true, or private subnets with a NAT gateway. | `list(string)` | yes |
| vpc\_id | VPC ID to deploy the ECS service and ALB into. | `string` | yes |
| additional\_security\_group\_ids | Additional security group IDs to attach to Fargate tasks. | `list(string)` | no |
| alb\_certificate\_arns | ACM certificate ARNs for the HTTPS listener. When non-empty, creates a port 443 HTTPS listener. The first ARN is the primary certificate; additional ARNs are attached as SNI extras. | `list(string)` | no |
| alb\_deletion\_protection | Enable deletion protection on the ALB. | `bool` | no |
| alb\_deregistration\_delay | Seconds the ALB waits before deregistering a target during deployments and scale-in. Must be >= alb\_idle\_timeout to avoid in-flight connection resets. | `number` | no |
| alb\_idle\_timeout | ALB connection idle timeout in seconds. | `number` | no |
| alb\_redirect\_http\_to\_https | Redirect HTTP to HTTPS on the ALB. Requires alb\_certificate\_arns to be set. | `bool` | no |
| alb\_subnet\_ids | Subnet IDs for the Application Load Balancer. When null, uses subnet\_ids. Set to public subnets when tasks are in private subnets. | `list(string)` | no |
| allow\_public\_access | Allow public internet access to the ALB (0.0.0.0/0 on port 80/443). | `bool` | no |
| assign\_public\_ip | Assign a public IP to Fargate tasks. Required in public subnets to pull container images from public registries. Set to false when using private subnets with a NAT gateway. | `bool` | no |
| cache\_bucket | S3 bucket name for imgproxy result cache (imgproxy Pro only). The task role is granted full object access. | `string` | no |
| cdn\_default\_ttl | Default CloudFront TTL in seconds. Set to 0 to let CloudFront respect origin Cache-Control headers. | `number` | no |
| cdn\_max\_ttl | Maximum CloudFront TTL in seconds, regardless of origin headers. | `number` | no |
| cdn\_min\_ttl | Minimum CloudFront TTL in seconds. Set to a positive value to force a floor TTL regardless of origin headers. | `number` | no |
| cdn\_redirect\_http\_to\_https | Redirect HTTP to HTTPS at the CloudFront level. | `bool` | no |
| cdn\_waf\_web\_acl\_id | WAF Web ACL ARN to associate with the CloudFront distribution. | `string` | no |
| cloudfront\_certificate\_arn | ACM certificate ARN for CloudFront (must be in us-east-1). Required when cloudfront\_domains is set. | `string` | no |
| cloudfront\_domains | Custom domain aliases for the CloudFront distribution. Requires cloudfront\_certificate\_arn. | `list(string)` | no |
| cloudfront\_origin\_shield\_region | AWS region to enable CloudFront Origin Shield (e.g. "us-east-1"). Adds an extra caching tier between edge locations and the ALB, reducing origin load. When null, Origin Shield is disabled. | `string` | no |
| cpu | vCPUs allocated to the imgproxy task (0.25, 0.5, 1, 2, 4, 8, 16). Fargate maps this to CPU units (cpu × 1024). Sets IMGPROXY\_WORKERS default. | `number` | no |
| cpu\_architecture | CPU architecture for the Fargate task. ARM64 (Graviton) is recommended — lower cost, same performance. Must match the image platform. | `string` | no |
| create\_alb | Create an Application Load Balancer for the ECS service. | `bool` | no |
| deployment\_minimum\_healthy\_percent | Minimum percentage of healthy tasks during a rolling deployment. 100 = zero-downtime (new task starts before old stops). 0 = fastest deploy (brief outage). With task\_min\_count = 1, a value of 50 allows a zero-task gap. | `number` | no |
| desired\_count | Desired number of ECS tasks. Defaults to task\_min\_count. Changes after initial creation are ignored (managed by ECS auto-scaling). | `number` | no |
| enable\_cloudfront | Create a CloudFront distribution in front of the ALB for global edge caching. Requires create\_alb = true. | `bool` | no |
| enable\_monitoring | Enable the AWS Distro for OpenTelemetry (ADOT) sidecar container to export traces to X-Ray and metrics/logs to CloudWatch. Automatically configures imgproxy OTEL environment variables. | `bool` | no |
| environment | Additional environment variables passed to imgproxy (e.g. IMGPROXY\_MAX\_SRC\_RESOLUTION). | `map(string)` | no |
| execution\_role\_arn | ARN of an existing IAM role to use as the ECS task execution role. When null, a role is created with ECR pull and Secrets Manager access. | `string` | no |
| insecure | Disable URL signature checks. When true, key and salt are not required. | `bool` | no |
| internal\_alb | Create an internal (non-internet-facing) ALB. Use for private deployments accessed via VPC only. | `bool` | no |
| keys\_secret | Secrets Manager ARN for imgproxy signing keys (comma-separated hex-encoded values). Required when insecure = false. Generate: openssl rand -hex 64. Sets IMGPROXY\_KEY. | ```object({ arn = string version = optional(string, "") })``` | no |
| log\_retention\_days | CloudWatch log group retention in days. | `number` | no |
| memory | Memory limit for the Fargate task. Accepts Mi or Gi suffix (e.g. '2048Mi', '4Gi'). Must satisfy Fargate CPU/memory constraints: 1 vCPU requires 2–8 GB, 2 vCPU requires 4–16 GB. | `string` | no |
| otel\_collector\_config | OpenTelemetry Collector configuration YAML passed to the ADOT sidecar via AOT\_CONFIG\_CONTENT. When null, a default config exporting to X-Ray and CloudWatch is used. | `string` | no |
| pro | Use imgproxy Pro (docker.imgproxy.pro) instead of the community image (ghcr.io) as the default repo. Has no effect when repo is set. | `bool` | no |
| pro\_license\_key\_secret | Secrets Manager ARN for the imgproxy Pro license key. Sets IMGPROXY\_LICENSE\_KEY. | ```object({ arn = string version = optional(string, "") })``` | no |
| repo | Container repository to pull imgproxy from, without tag (e.g. 'registry.example.com/imgproxy' or '123456789012.dkr.ecr.us-east-1.amazonaws.com/imgproxy'). When null, 'pro' selects docker.imgproxy.pro/imgproxy or ghcr.io/imgproxy/imgproxy. ECR repositories in the same account are pulled with the execution role and need no credentials; for any other private registry set repo\_credentials\_secret. | `string` | no |
| repo\_credentials\_secret | Secrets Manager secret with the credentials for the registry in 'repo' (or docker.imgproxy.pro when 'repo' is not set). Must be a JSON secret with 'username' and 'password' keys (ECS repositoryCredentials). Required when pro = true and repo is not set; the execution role is granted read access to it. | ```object({ arn = string })``` | no |
| salts\_secret | Secrets Manager ARN for imgproxy signing salts (must match number of keys). Required when insecure = false. Sets IMGPROXY\_SALT. | ```object({ arn = string version = optional(string, "") })``` | no |
| secret\_secret | Secrets Manager ARN for the authorization token. When set, requests must include Authorization: Bearer <token>. Sets IMGPROXY\_SECRET. | ```object({ arn = string version = optional(string, "") })``` | no |
| secrets | Map of environment variable names to Secrets Manager ARNs. Example: {IMGPROXY\_NEW\_RELIC\_KEY = {arn = "arn:aws:secretsmanager:us-east-1:123:secret:newrelic-key"}}. | ```map(object({ arn = string version = optional(string, "") }))``` | no |
| service\_name | Prefix applied to every resource name. | `string` | no |
| signature\_size | Number of bytes from the key/salt used for signing. Sets IMGPROXY\_SIGNATURE\_SIZE. | `number` | no |
| source\_buckets | S3 bucket names for imgproxy source images. The task role is granted s3:GetObject on each. Enables IMGPROXY\_USE\_S3. | `list(string)` | no |
| source\_url\_encryption\_key\_secret | Secrets Manager ARN for the source URL encryption key. Sets IMGPROXY\_SOURCE\_URL\_ENCRYPTION\_KEY. | ```object({ arn = string version = optional(string, "") })``` | no |
| spot\_percentage | Percentage of tasks to run on FARGATE\_SPOT (0–99). At 0, only FARGATE is used. At 1–99, both providers are used with weights proportional to the percentage. Must be less than 100. | `number` | no |
| tag | imgproxy image tag (version). | `string` | no |
| tags | Tags applied to all created resources. | `map(string)` | no |
| task\_max\_count | Maximum number of ECS tasks for Application Auto Scaling. | `number` | no |
| task\_min\_count | Minimum number of ECS tasks for Application Auto Scaling. | `number` | no |
| task\_role\_arn | ARN of an existing IAM role to use as the ECS task role. When null, a role is created with S3 and monitoring permissions as needed. | `string` | no |
| timeout | Request timeout in seconds. Sets IMGPROXY\_TIMEOUT. | `number` | no |
| trusted\_signatures\_secret | Secrets Manager ARN for trusted signature prefixes. imgproxy Pro only. Sets IMGPROXY\_TRUSTED\_SIGNATURES. | ```object({ arn = string version = optional(string, "") })``` | no |
| workers | Number of concurrent requests per container. Sets IMGPROXY\_WORKERS. Defaults to cpu × 2. | `number` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| alb\_dns\_name | DNS name of the Application Load Balancer. |
| alb\_zone\_id | Hosted zone ID of the ALB. Use with Route 53 alias records. |
| cloudfront\_domain\_name | CloudFront distribution domain name. |
| cloudfront\_hosted\_zone\_id | CloudFront hosted zone ID. Use with Route 53 alias records. |
| cluster\_arn | ECS cluster ARN. |
| cluster\_name | ECS cluster name. |
| execution\_role\_arn | ARN of the IAM role used by the ECS agent to start tasks. |
| log\_group\_name | CloudWatch Log Group name for imgproxy and OTEL sidecar logs. |
| service\_name | ECS service name. |
| task\_role\_arn | ARN of the IAM role used by the imgproxy task at runtime. |
| tasks\_security\_group\_id | Security group ID attached to Fargate tasks. |
| url | imgproxy endpoint URL. CloudFront domain when enable\_cloudfront = true, otherwise ALB DNS name. |
<!-- END_TF_DOCS -->

## License

MIT
