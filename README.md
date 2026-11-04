# imgproxy Terraform Module for AWS ECS (Fargate)

Terraform module to deploy [imgproxy](https://imgproxy.net/) on AWS ECS with Fargate, behind an Application Load Balancer, with optional CloudFront, OpenTelemetry monitoring and S3 integration.

## Features

- **Fargate and Fargate Spot** (`spot_percentage`), with auto scaling on imgproxy's own metrics
- **Secure by default**: tasks without public IPs and HTTPS required on the load balancer ([details](#secure-defaults))
- **Application Load Balancer** with ACM certificates and HTTP to HTTPS redirect
- **CloudFront CDN**, with the load balancer locked to CloudFront
- **imgproxy Pro and private registries** through Secrets Manager
- **Request signing** with keys and salts from Secrets Manager
- **OpenTelemetry sidecar** (ADOT) for traces to X-Ray and metrics and logs to CloudWatch
- **S3** for source images and the result cache (Pro)
- **IAM execution and task roles**, created for you or supplied

## Usage

```hcl
module "imgproxy" {
  source  = "imgproxy/imgproxy-fargate/aws"
  version = "~> 0.1"

  service_name = "imgproxy"

  # Tasks in private subnets, internet-facing ALB in public subnets
  vpc_id         = "vpc-0123456789abcdef0"
  subnet_ids     = ["subnet-0aaa...", "subnet-0bbb..."] # private: the tasks
  alb_subnet_ids = ["subnet-0ccc...", "subnet-0ddd..."] # public: the ALB

  # HTTPS on the ALB (point a DNS record for the domain at it)
  alb_certificate_arns = ["arn:aws:acm:us-east-1:123456789012:certificate/..."]

  keys_secret  = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy-keys-AbCdEf" }
  salts_secret = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:imgproxy-salts-AbCdEf" }

  spot_percentage = 70 # run part of the tasks on Fargate Spot to save cost
}
```

## Prerequisites

- An AWS account with [sufficient permissions](#permissions) and the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) authenticated
- An existing VPC with subnets: the module creates no networking (see [Networking](#networking))
- Terraform >= 1.5

## Examples

Start with [insecure](examples/insecure/) and follow the "Next" link at the end of each README; every step adds one feature.

- [insecure](examples/insecure/) - Minimal deployment without request signing (development only)
- [signed](examples/signed/) - URL signing, plus the [production setup](examples/signed/#production-setup) with private subnets and HTTPS
- [s3](examples/s3/) - Private S3 bucket as the image source
- [cdn](examples/cdn/) - CloudFront in front of the load balancer
- [pro](examples/pro/) - imgproxy Pro with license key and S3 result cache
- [complete](examples/complete/) - Pro, monitoring and S3 together

All examples use Fargate Spot. To stay self-contained they run in the default VPC over plain HTTP, so they set `assign_public_ip = true` and `allow_insecure_http = true` explicitly. That is for testing only.

## Notes

### Secure defaults

Each insecure choice is an explicit, named opt-in:

| Default | Opt-in | Acceptable for |
|---------|--------|----------------|
| Tasks have no public IP | `assign_public_ip = true` | Public subnets such as the default VPC. Each task is then addressable by IP (the security group still admits only the ALB on port 8080) |
| The ALB requires HTTPS (`alb_certificate_arns`) | `allow_insecure_http = true` | Testing: traffic, signed URLs and tokens are unencrypted. With CloudFront, the origin secret header is too |
| Requests must be signed | `insecure = true` | Development: anyone can use your imgproxy and, with `source_buckets`, read those buckets |

Without a certificate and without `allow_insecure_http = true`, the module refuses to plan.

### Permissions

The deployer needs permissions for ECS, the load balancer, security groups, Application Auto Scaling, CloudWatch alarms and log groups, and CloudFront. Two example policies. Before pasting either into a permission set or IAM policy, edit it:

- Replace **`123456789012`** with your own 12-digit AWS account ID (`aws sts get-caller-identity --profile my-profile --query Account --output text`). It appears in the `iam:` statements' `Resource` ARNs (`arn:aws:iam::123456789012:role/...`).
- Replace the **`imgproxy`** role-name prefix (`role/imgproxy-*`, or `role/imgproxy-execution` and `role/imgproxy-task` in the second file) if your `service_name` is not `imgproxy`: the module names its roles `<service_name>-execution-*` and `<service_name>-task-*`.

The JSON files cannot carry comments (IAM rejects unknown keys), so this note lives here. After saving a change to an IAM Identity Center permission set, reprovision it on the account and run `aws sso login` again.

- [example-permission-set.json](example-permission-set.json): the module creates the task execution and task roles, which is why the deployer needs IAM access at all. It is limited to roles named `imgproxy-*`, allows attaching only `AmazonECSTaskExecutionRolePolicy`, and allows `iam:PassRole` only to ECS tasks. Someone who can write inline policies on those roles still controls what they may do, so treat this identity as privileged.
- [example-permission-set-existing-roles.json](example-permission-set-existing-roles.json): you create the roles and pass them as `execution_role_arn` and `task_role_arn`. The deployer then needs only `iam:PassRole` on them. The task role needs the S3 and monitoring access the module would otherwise grant; the execution role needs the ECS managed policy plus read access to your secrets.

Neither policy reads secret values or covers the Terraform state backend. They were written from the module's resources and not applied end to end against AWS, so adjust them if an apply fails with `AccessDenied`.

### Networking

Run the tasks in private subnets and keep only the ALB public, as in Usage. `assign_public_ip = false` is the default.

- `alb_subnet_ids` must be public subnets. When unset, the ALB goes into `subnet_ids`, the private ones, and is unreachable from the internet. `internal_alb = true` makes an ALB reachable only from the VPC and connected networks (peering, VPN, Direct Connect).
- Private tasks need an outbound route: imgproxy fetches images from the internet and the task pulls from `ghcr.io` (or `docker.imgproxy.pro`). Use a **NAT gateway**; without one, tasks fail with `CannotPullContainerError`. With S3 sources and an ECR image, VPC endpoints can replace it: an S3 gateway endpoint (free) plus interface endpoints for `ecr.api`, `ecr.dkr`, `secretsmanager` and `logs`.
- The task security group admits only the ALB on port 8080. Add VPN or bastion rules through `tasks_security_group_id` or `additional_security_group_ids`.
- Quick start: tasks in public subnets, such as the default VPC, need an explicit `assign_public_ip = true`, or they cannot pull their image. Testing only.

### Additional secrets

`secrets` maps extra environment variables (named as in [imgproxy's configuration](https://docs.imgproxy.net/configuration)) to Secrets Manager secrets:

```hcl
secrets = {
  IMGPROXY_SENTRY_DSN  = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:sentry-dsn-AbCdEf" }
  IMGPROXY_BUGSNAG_KEY = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:bugsnag-api-key-AbCdEf", version = "3" }
}
```

`version` is a Secrets Manager version ID; the current version is used when it is omitted. An execution role created by the module can read every secret you pass.

### Image delivery

Fargate pulls the image directly: `ghcr.io/imgproxy/imgproxy`, or `docker.imgproxy.pro/imgproxy` with `pro = true`. For your own image, set `repo` (without tag) and `tag` (a version, or a `sha256:` digest referenced as `repo@sha256:...`):

```hcl
repo                    = "registry.example.com/imgproxy-custom"
repo_credentials_secret = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:registry-AbCdEf" }
tag                     = "my-tag"
```

- **ECR** in your account and public images need no credentials. The module-created execution role can pull from ECR; a custom `execution_role_arn` needs the usual ECR pull permissions.
- Any other **private registry** needs `repo_credentials_secret`: a JSON secret with `username` and `password` keys (ECS `repositoryCredentials`). The module-created execution role can read it; grant a custom one `secretsmanager:GetSecretValue` yourself.
- `pro = true` only selects the default `repo` and has no effect when `repo` is set. For docker.imgproxy.pro only `repo_credentials_secret` is required (username `imgproxy`).

Tasks run on ARM64 (Graviton) by default, so the image must support `linux/arm64`; otherwise set `cpu_architecture = "X86_64"`.

### Fargate Spot and scaling

`spot_percentage` (0-99) runs that share of the tasks on `FARGATE_SPOT`, which costs up to 70% less (`70` means weights 30 and 70). One task always stays on regular Fargate (`base = 1`), and ECS replaces reclaimed Spot tasks because imgproxy is stateless. With `task_min_count = 1` the single task is the on-demand one, and Spot is used only on scale-out.

Tasks scale between `task_min_count` and `task_max_count` with step policies on imgproxy's `WorkersUtilization` metric (out above 80%, in below 50%), which imgproxy publishes through the `IMGPROXY_CLOUD_WATCH_*` variables the module always sets. Terraform ignores later changes to the task count.

### Monitoring, S3 and logs

- `enable_monitoring = true` adds an ADOT collector sidecar (OTLP on `localhost:4318`) that exports traces to X-Ray and metrics and logs to CloudWatch, with matching task-role permissions and Container Insights. It reserves 256Mi of the task memory; replace its configuration with `otel_collector_config`.
- `source_buckets` and `cache_bucket` (Pro) get IAM permissions on existing buckets; the module does not create them. `source_buckets` enables the `s3://` scheme, and the cache is configured through `environment`. Set `IMGPROXY_S3_REGION` there when the bucket is not in the default region.
- The service exposes `/health` on port 8080. Logs go to the CloudWatch group `/aws/ecs/<service_name>` (`log_group_name` output), kept for `log_retention_days` (365 by default).

### CloudFront

`enable_cloudfront = true` puts CloudFront in front of the ALB (`create_alb` must stay `true`), on its `*.cloudfront.net` domain or on yours through `cloudfront_domains` and `cloudfront_certificate_arn` (issued in **us-east-1**).

The ALB is locked to CloudFront: its security group admits only CloudFront's origin-facing IPs, and the listener returns `403` unless the request carries the module-generated secret `X-Origin-Verify` header. That only holds if the CloudFront-to-ALB hop is encrypted, so the module requires HTTPS there:

```hcl
enable_cloudfront        = true
alb_certificate_arns     = ["arn:aws:acm:us-east-1:123456789012:certificate/..."] # covers origin.example.com
cloudfront_origin_domain = "origin.example.com"
```

CloudFront validates the ALB certificate against the origin's domain name, so it cannot use the ALB's own `*.elb.amazonaws.com` name with your certificate. `cloudfront_origin_domain` is a dedicated name: cover it with the ALB certificate and point a DNS record at the ALB (`alb_dns_name` and `alb_zone_id` outputs). It must differ from `cloudfront_domains`, and a certificate without it fails to plan.

For testing without a domain, `allow_insecure_http = true` makes that hop plain HTTP: anyone who captures the secret header bypasses the lock, and the traffic is unencrypted.

Cache keys follow your imgproxy configuration (`Accept` with format detection, client hints, `IMGPROXY_CACHE_KEY_HEADERS` and `IMGPROXY_CACHE_KEY_COOKIES`). `secret_secret` cannot be combined with CloudFront, which does not forward the `Authorization` header. Query strings are not forwarded or cached either, so percent-encode any `?` in plain source URLs.

### Vendored modules

`modules/aws-common` and `modules/imgproxy-common` are generated copies from `imgproxy/terraform-common`. Do not edit them here: change them upstream and run its `sync.sh`.

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
| subnet\_ids | Subnet IDs for Fargate tasks. Use private subnets with a NAT gateway (recommended), or public subnets with assign\_public\_ip = true. | `list(string)` | yes |
| vpc\_id | VPC ID to deploy the ECS service and ALB into. | `string` | yes |
| additional\_security\_group\_ids | Additional security group IDs to attach to Fargate tasks. | `list(string)` | no |
| alb\_certificate\_arns | ACM certificate ARNs for the HTTPS listener. Required unless allow\_insecure\_http = true. Creates a port 443 HTTPS listener; the first ARN is the primary certificate and additional ARNs are attached as SNI extras. | `list(string)` | no |
| alb\_deletion\_protection | Enable deletion protection on the ALB. | `bool` | no |
| alb\_deregistration\_delay | Seconds the ALB waits before deregistering a target during deployments and scale-in. Must be >= alb\_idle\_timeout to avoid in-flight connection resets. | `number` | no |
| alb\_idle\_timeout | ALB connection idle timeout in seconds. | `number` | no |
| alb\_redirect\_http\_to\_https | Redirect HTTP to HTTPS on the ALB. Requires alb\_certificate\_arns to be set. | `bool` | no |
| alb\_subnet\_ids | Subnet IDs for the Application Load Balancer. When null, uses subnet\_ids. Set to public subnets when tasks are in private subnets. | `list(string)` | no |
| allow\_insecure\_http | Allow the ALB to serve plain HTTP only, that is, without alb\_certificate\_arns. For testing only: requests, signed URLs and tokens travel unencrypted. With CloudFront it also makes CloudFront reach the ALB over plain HTTP, so the origin secret header and all traffic cross the network in clear text. | `bool` | no |
| allow\_public\_access | Allow public internet access to the ALB (0.0.0.0/0 on port 80/443). | `bool` | no |
| assign\_public\_ip | Assign a public IP to Fargate tasks. Off by default: run the tasks in private subnets with a NAT gateway (or VPC endpoints). Set to true only when the subnets are public, such as those of the default VPC: tasks then need it to pull the image, and every task is directly addressable by IP (the task security group still only accepts the ALB on port 8080). | `bool` | no |
| cache\_bucket | S3 bucket name for imgproxy result cache (imgproxy Pro only). The task role is granted full object access. | `string` | no |
| cdn\_default\_ttl | Default CloudFront TTL in seconds. Set to 0 to let CloudFront respect origin Cache-Control headers. | `number` | no |
| cdn\_max\_ttl | Maximum CloudFront TTL in seconds, regardless of origin headers. | `number` | no |
| cdn\_min\_ttl | Minimum CloudFront TTL in seconds. Set to a positive value to force a floor TTL regardless of origin headers. | `number` | no |
| cdn\_redirect\_http\_to\_https | Redirect HTTP to HTTPS at the CloudFront level. | `bool` | no |
| cdn\_waf\_web\_acl\_id | WAF Web ACL ARN to associate with the CloudFront distribution. | `string` | no |
| cloudfront\_certificate\_arn | ACM certificate ARN for CloudFront (must be in us-east-1). Required when cloudfront\_domains is set. | `string` | no |
| cloudfront\_domains | Custom domain aliases for the CloudFront distribution. Requires cloudfront\_certificate\_arn. | `list(string)` | no |
| cloudfront\_origin\_domain | Domain name CloudFront uses to reach the ALB over HTTPS, for example 'origin.example.com'. Create a DNS record for it that points at the ALB (see the alb\_dns\_name and alb\_zone\_id outputs) and cover it with a certificate in alb\_certificate\_arns. Required when enable\_cloudfront = true and alb\_certificate\_arns is set, because CloudFront validates the ALB certificate against this name. Must differ from cloudfront\_domains. | `string` | no |
| cloudfront\_origin\_shield\_region | AWS region to enable CloudFront Origin Shield (e.g. "us-east-1"). Adds an extra caching tier between edge locations and the ALB, reducing origin load. When null, Origin Shield is disabled. | `string` | no |
| cpu | vCPUs allocated to the imgproxy task (0.25, 0.5, 1, 2, 4, 8, 16). Fargate maps this to CPU units (cpu × 1024). Sets IMGPROXY\_WORKERS default. | `number` | no |
| cpu\_architecture | CPU architecture for the Fargate task. ARM64 (Graviton) is recommended — lower cost, same performance. Must match the image platform. | `string` | no |
| create\_alb | Create an Application Load Balancer for the ECS service. | `bool` | no |
| deployment\_minimum\_healthy\_percent | Minimum percentage of healthy tasks during a rolling deployment. 100 = zero-downtime (new task starts before old stops). 0 = fastest deploy (brief outage). With task\_min\_count = 1, a value of 50 allows a zero-task gap. | `number` | no |
| desired\_count | Desired number of ECS tasks. Defaults to task\_min\_count. Changes after initial creation are ignored (managed by ECS auto-scaling). | `number` | no |
| enable\_cloudfront | Create a CloudFront distribution in front of the ALB for global edge caching. Requires create\_alb = true. | `bool` | no |
| enable\_monitoring | Enable the AWS Distro for OpenTelemetry (ADOT) sidecar container to export traces and metrics to X-Ray and CloudWatch. Automatically configures imgproxy OTEL environment variables. | `bool` | no |
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
| source\_buckets | S3 bucket names for imgproxy source images. The task role is granted s3:GetObject, s3:GetObjectVersion and s3:ListBucket on each. Enables IMGPROXY\_USE\_S3. | `list(string)` | no |
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
| alb\_security\_group\_id | Security group ID of the Application Load Balancer (null without an ALB). Use it to add ingress rules, e.g. for an internal ALB. |
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
