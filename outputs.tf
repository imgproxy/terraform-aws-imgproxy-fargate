output "url" {
  description = "imgproxy endpoint URL. CloudFront domain when enable_cloudfront = true, otherwise ALB DNS name."
  value       = module.aws_common.url
}

output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.main.name
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.main.name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.main.arn
}

output "task_role_arn" {
  description = "ARN of the IAM role used by the imgproxy task at runtime."
  value       = module.aws_common.task_role_arn
}

output "execution_role_arn" {
  description = "ARN of the IAM role used by the ECS agent to start tasks."
  value       = module.aws_common.execution_role_arn
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer."
  value       = module.aws_common.alb_dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the ALB. Use with Route 53 alias records."
  value       = module.aws_common.alb_zone_id
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name."
  value       = module.aws_common.cloudfront_domain_name
}

output "cloudfront_hosted_zone_id" {
  description = "CloudFront hosted zone ID. Use with Route 53 alias records."
  value       = module.aws_common.cloudfront_hosted_zone_id
}

output "tasks_security_group_id" {
  description = "Security group ID attached to Fargate tasks."
  value       = aws_security_group.tasks.id
}

output "log_group_name" {
  description = "CloudWatch Log Group name for imgproxy and OTEL sidecar logs."
  value       = module.aws_common.log_group_name
}
