# Signed URLs

Production imgproxy with request signing, so only URLs signed with your key and salt are processed.

## AWS setup

You need an AWS account and the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
authenticated:

```bash
aws configure
# or: aws sso login --profile your-profile && export AWS_PROFILE=your-profile
```

## Prerequisites

Create the signing keys and store them in Secrets Manager:

```bash
REGION=us-east-1

aws secretsmanager create-secret --region $REGION --name imgproxy-keys --secret-string "$(openssl rand -hex 64)"
aws secretsmanager create-secret --region $REGION --name imgproxy-salts --secret-string "$(openssl rand -hex 64)"
```

## Deploy

```bash
echo "region = \"$REGION\"" > terraform.tfvars

terraform init
terraform plan
terraform apply

# Unsigned requests are rejected (give the tasks a couple of minutes to become healthy first)
curl -I "$(terraform output -raw url)/insecure/plain/https://picsum.photos/200"   # 403 Forbidden
```

Print a signed URL (paste it into a browser):

```bash
(
URL=$(terraform output -raw url)
KEY=$(aws secretsmanager get-secret-value --region $REGION --secret-id imgproxy-keys --query SecretString --output text)
SALT=$(aws secretsmanager get-secret-value --region $REGION --secret-id imgproxy-salts --query SecretString --output text)
IMG_PATH="/rs:fit:300:300/plain/https://picsum.photos/1200/800.jpg"
SIG=$( (printf '%s' "$SALT" | xxd -r -p; printf '%s' "$IMG_PATH") \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:$KEY -binary \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=' )
echo "$URL/$SIG$IMG_PATH"
)
```

This assumes a single key/salt pair. See [imgproxy's signing algorithm](https://docs.imgproxy.net/usage/signing_the_url) for details.

## Private subnets

This example runs in the default VPC, whose subnets are public, so the tasks get public IPs (`assign_public_ip = true`,
the module default). That is only meant for trying the module out. **In production, run the tasks in private subnets**
and keep only the load balancer public:

```hcl
vpc_id           = "vpc-0123456789abcdef0"
subnet_ids       = ["subnet-0aaa...", "subnet-0bbb..."] # private subnets: the tasks
alb_subnet_ids   = ["subnet-0ccc...", "subnet-0ddd..."] # public subnets: the internet-facing ALB
assign_public_ip = false
```

- Set `alb_subnet_ids` to public subnets. If you leave it unset, the ALB is placed in `subnet_ids`, that is, in the
  private subnets, and is not reachable from the internet. For an ALB reachable only from inside the VPC, use
  `internal_alb = true` instead.
- With `assign_public_ip = false`, the tasks need an outbound route. imgproxy downloads source images from the
  internet and the task pulls its image from `ghcr.io` (or `docker.imgproxy.pro`), so the private subnets need a **NAT
  gateway**. Without one, tasks fail to start with `CannotPullContainerError`.
- If your source images only live in S3 and the image comes from ECR, you can skip the NAT gateway and use VPC
  endpoints instead: an S3 gateway endpoint (free) plus interface endpoints for `ecr.api`, `ecr.dkr`,
  `secretsmanager` and `logs`.
- The task security group only accepts traffic on port 8080 from the ALB, so private tasks are not reachable from
  anywhere else. Add rules for VPN or bastion access through the `tasks_security_group_id` output.

The other examples keep using the default VPC for brevity; the same settings apply to all of them.

## Cleanup

```bash
terraform destroy
```

The secrets created in Prerequisites are not managed by Terraform; delete them separately:

```bash
aws secretsmanager delete-secret --region $REGION --secret-id imgproxy-keys --force-delete-without-recovery
aws secretsmanager delete-secret --region $REGION --secret-id imgproxy-salts --force-delete-without-recovery
```

## Next

Continue with [s3](../s3/).
