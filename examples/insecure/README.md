# Insecure mode

Minimal imgproxy on ECS Fargate with no request signing (`insecure = true`): community edition, default resource
limits, a public Application Load Balancer, Fargate Spot, no monitoring and no S3. It fetches public placeholder
images.

> [!WARNING]
> This example is intended for **development and testing only**. Without request signing anyone can use your
> imgproxy (unlimited bandwidth costs, no protection against abuse, no control over processed images). Never use
> this configuration in production.

## Testing opt-ins

The module is private and encrypted by default: tasks get no public IPs and the load balancer requires HTTPS. This
example has no VPC of its own and no domain, so it waives both defaults explicitly:

```hcl
assign_public_ip    = true # the default VPC has only public subnets, so tasks need a public IP to pull the image
allow_insecure_http = true # plain HTTP on the ALB (no domain and certificate here): requests are unencrypted
```

Every example in this repository does the same, for testing only. For a production setup, with the tasks in private
subnets and HTTPS on the load balancer, see [signed](../signed/#production-setup).

## AWS setup

You need an AWS account and the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
authenticated (the [permissions](../../example-permission-set.json) the module needs are listed in the repository root):

```bash
aws configure
# or: aws sso login --profile my-profile && export AWS_PROFILE=my-profile
```

> The `aws` commands below use `--profile my-profile`: replace it with your profile, or drop it if you use the default credentials.
> An `aws: [ERROR]: An error occurred (ForbiddenException) when calling the GetRoleCredentials operation: No access` error usually means the profile is missing or wrong.

## Prerequisites

```bash
REGION=us-east-1
```

## Deploy

```bash
echo "region = \"$REGION\"" > terraform.tfvars

terraform init
terraform plan
terraform apply
```

The tasks need a couple of minutes to start and pass the load balancer health check. Print a ready-to-open URL
(paste it into a browser; no signature is required in insecure mode):

```bash
echo "$(terraform output -raw url)/insecure/rs:fit:300:300/plain/https://picsum.photos/1200/800.jpg"
```

## Fargate Spot

`spot_percentage = 70` runs about 70% of the tasks on `FARGATE_SPOT`, which is up to 70% cheaper than regular
Fargate. One task always runs on regular Fargate (`base = 1`), so the service never depends on Spot capacity alone.
A Spot task can be reclaimed with a two-minute warning; imgproxy is stateless, so ECS just starts a replacement.

## Cleanup

```bash
terraform destroy
```

## Next

Continue with [signed](../signed/).
