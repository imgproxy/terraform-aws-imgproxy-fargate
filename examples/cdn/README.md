# CloudFront CDN

A CloudFront distribution in front of the load balancer, caching processed images at edge locations. A domain name is
optional: this example serves the CDN on its own `*.cloudfront.net` domain over HTTPS (see below for adding your own
domain). It fetches public placeholder images, so no bucket is needed.

## AWS setup

You need an AWS account and the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
authenticated:

```bash
aws configure
# or: aws sso login --profile your-profile && export AWS_PROFILE=your-profile
```

## Prerequisites

Create the signing keys (see [signed](../signed/)):

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
```

CloudFront takes 5-10 minutes to deploy, and the tasks need a couple of minutes to become healthy. Print a signed URL
for a placeholder image and request it twice:

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

# Repeated requests for the same URL: the second response says "Hit from cloudfront" and carries an Age header
curl -sI "<url from above>" | grep -i -E '^(HTTP|x-cache|age)'
```

## Adding a domain

In [main.tf](main.tf), uncomment `cloudfront_domains` and `cloudfront_certificate_arn`. The certificate must be issued
in **us-east-1** (an ACM requirement for CloudFront), whatever region the service runs in. After `terraform apply`,
point your domain at `terraform output cloudfront_domain_name` with a CNAME record, or with a Route 53 alias record
using `terraform output cloudfront_hosted_zone_id`. The `url` output then returns `https://<your domain>`.

## Locked-down origin

With CloudFront enabled, the load balancer only accepts traffic from CloudFront: its security group admits just the
CloudFront origin-facing IP ranges, and the listener returns `403` unless the request carries a secret
`X-Origin-Verify` header that only your distribution adds. Direct requests to the ALB DNS name are rejected, so all
traffic goes through the CDN.

Without `alb_certificate_arns`, CloudFront connects to the ALB over plain HTTP, so traffic between the two is not
encrypted. Set `alb_certificate_arns` to have CloudFront use HTTPS to the origin as well.

Cache keys follow your imgproxy configuration: the `Accept` header is added when format detection
(`IMGPROXY_AUTO_WEBP`, `IMGPROXY_AUTO_AVIF`, ...) is enabled, the client hints headers with
`IMGPROXY_ENABLE_CLIENT_HINTS`, and so on. An authorization token (`secret_secret`) cannot be combined with
CloudFront, which does not forward the `Authorization` header.

## Cleanup

```bash
terraform destroy
```

The secrets were created with the AWS CLI, so delete them separately (and remove the DNS record if you added a domain):

```bash
aws secretsmanager delete-secret --region $REGION --secret-id imgproxy-keys --force-delete-without-recovery
aws secretsmanager delete-secret --region $REGION --secret-id imgproxy-salts --force-delete-without-recovery
```

## Next

Continue with [pro](../pro/).
