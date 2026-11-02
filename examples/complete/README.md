# Complete imgproxy Deployment Example

This example demonstrates a full-featured imgproxy deployment on ECS Fargate with all available features:

- imgproxy Pro with license key
- Request signing with configurable key size
- Source URL encryption
- Authorization token (Bearer auth)
- OpenTelemetry-based monitoring (ADOT sidecar to X-Ray and CloudWatch)
- S3 integration for source images and result cache
- CloudFront CDN with a global edge cache
- Fargate Spot for cost savings
- Additional secrets for third-party integrations
- Custom resource limits, concurrency, and scaling
- Resource tags

## AWS setup

You need an AWS account and the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
authenticated:

```bash
aws configure
# or: aws sso login --profile your-profile && export AWS_PROFILE=your-profile
```

## Prerequisites

**Create Secrets Manager secrets and S3 buckets:**

```bash
REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Signing keys (required)
aws secretsmanager create-secret --region $REGION --name imgproxy-keys --secret-string "$(openssl rand -hex 64)"
aws secretsmanager create-secret --region $REGION --name imgproxy-salts --secret-string "$(openssl rand -hex 64)"

# imgproxy Pro (if using pro = true); the registry secret is JSON, for docker.imgproxy.pro or for your own registry set via repo
aws secretsmanager create-secret --region $REGION --name imgproxy-pro-license --secret-string "your-license-key"
aws secretsmanager create-secret --region $REGION --name imgproxy-pro-registry \
  --secret-string '{"username":"imgproxy","password":"your-registry-password"}'

# Optional: authorization token (Bearer auth; cannot be used together with CloudFront)
aws secretsmanager create-secret --region $REGION --name imgproxy-secret --secret-string "$(openssl rand -hex 32)"

# Optional: source URL encryption key
aws secretsmanager create-secret --region $REGION --name imgproxy-source-url-key --secret-string "$(openssl rand -hex 16)"

# S3 buckets for source images and the result cache (not managed by Terraform)
aws s3 mb s3://$ACCOUNT_ID-imgproxy-complete-source --region $REGION
aws s3 mb s3://$ACCOUNT_ID-imgproxy-complete-cache --region $REGION
```

## Deploy

Everything is configured in [main.tf](main.tf); edit it to enable the commented-out options (Bearer auth, source URL
encryption, trusted signatures, extra secrets, a custom registry, private subnets, HTTPS on the load balancer, a CloudFront
domain).

1. **Deploy:**

```bash
echo "region = \"$REGION\"" > terraform.tfvars

terraform init
terraform plan
terraform apply
```

2. **Access the service:**

```bash
terraform output url
```

3. **If you added a CloudFront domain, point DNS:**

```bash
# Get the CloudFront domain
terraform output cloudfront_domain_name

# Create a CNAME record pointing cdn.example.com to this domain
# (or a Route 53 alias record). The certificate must be issued in us-east-1.
```

## Testing S3 Integration

Upload a test image to the source bucket:

```bash
aws s3 cp test-image.jpg s3://$ACCOUNT_ID-imgproxy-complete-source/photo.jpg
```

Then access it via imgproxy using a signed URL:

```bash
(
URL=$(terraform output -raw url)
KEY=$(aws secretsmanager get-secret-value --region $REGION --secret-id imgproxy-keys --query SecretString --output text)
SALT=$(aws secretsmanager get-secret-value --region $REGION --secret-id imgproxy-salts --query SecretString --output text)
IMG_PATH="/plain/s3://$ACCOUNT_ID-imgproxy-complete-source/photo.jpg"
SIG=$( (printf '%s' "$SALT" | xxd -r -p; printf '%s' "$IMG_PATH") \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:$KEY -binary \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=' )
echo "$URL/$SIG$IMG_PATH"
)
```

## Verifying Monitoring

After deployment with `enable_monitoring = true`, verify telemetry is flowing:

1. Go to AWS Console → X-Ray → Traces and confirm new traces appear for imgproxy requests
2. Go to AWS Console → CloudWatch → Metrics → All metrics → Custom namespaces → `imgproxy`. The metrics appear within a
   minute or two of the first requests, for example `WorkersUtilization`, which also drives the task auto scaling
3. Go to AWS Console → CloudWatch → Log groups and open the group printed by `terraform output log_group_name`.
   imgproxy logs use the `imgproxy` stream prefix and the collector's use `otel`

## Cleanup

```bash
terraform destroy
```

The buckets and the secrets were created with the AWS CLI, so delete them separately (and remove the DNS record if you added a domain):

```bash
aws s3 rb s3://$ACCOUNT_ID-imgproxy-complete-source --force
aws s3 rb s3://$ACCOUNT_ID-imgproxy-complete-cache --force
aws secretsmanager delete-secret --region $REGION --secret-id imgproxy-keys --force-delete-without-recovery
aws secretsmanager delete-secret --region $REGION --secret-id imgproxy-salts --force-delete-without-recovery
aws secretsmanager delete-secret --region $REGION --secret-id imgproxy-pro-license --force-delete-without-recovery
aws secretsmanager delete-secret --region $REGION --secret-id imgproxy-pro-registry --force-delete-without-recovery
aws secretsmanager delete-secret --region $REGION --secret-id imgproxy-secret --force-delete-without-recovery
aws secretsmanager delete-secret --region $REGION --secret-id imgproxy-source-url-key --force-delete-without-recovery
```
