# Insecure mode

Minimal imgproxy on ECS Fargate with no request signing (`insecure = true`): community edition, default resource
limits, a public Application Load Balancer, Fargate Spot, no monitoring and no S3. It fetches public placeholder
images.

> [!WARNING]
> This example is intended for **development and testing only**. Without request signing anyone can use your
> imgproxy (unlimited bandwidth costs, no protection against abuse, no control over processed images). Never use
> this configuration in production.

It runs in the **default VPC**, whose subnets are public, so the tasks get public IPs. Production deployments should
run the tasks in private subnets instead: see [signed](../signed/#private-subnets).

## AWS setup

You need an AWS account and the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
authenticated (the [permissions](../../example-permission-set.json) the module needs are listed in the repository root):

```bash
aws configure
# or: aws sso login --profile your-profile && export AWS_PROFILE=your-profile
```

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
