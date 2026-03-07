# ── Input bucket ──────────────────────────────────────────────────────────────
output "input_bucket_name" {
  description = "Name of the S3 input bucket. Upload videos to s3://<bucket>/uploads/<file>."
  value       = aws_s3_bucket.input_bucket.bucket
}

output "input_bucket_arn" {
  description = "ARN of the input bucket."
  value       = aws_s3_bucket.input_bucket.arn
}

# ── Output bucket ─────────────────────────────────────────────────────────────
output "output_bucket_name" {
  description = "Name of the S3 output bucket. MediaConvert writes HLS output to processed/<name>/."
  value       = aws_s3_bucket.output_bucket.bucket
}

output "output_bucket_arn" {
  description = "ARN of the output bucket."
  value       = aws_s3_bucket.output_bucket.arn
}

# ── CloudFront ────────────────────────────────────────────────────────────────
output "cloudfront_domain_name" {
  description = "CloudFront domain name for HLS delivery. Use this as the base URL for video players. Empty if enable_cloudfront = false."
  value       = var.enable_cloudfront ? "https://${aws_cloudfront_distribution.hls_cdn[0].domain_name}" : ""
}

# ── Lambda ────────────────────────────────────────────────────────────────────
output "lambda_function_name" {
  description = "Name of the Lambda function."
  value       = aws_lambda_function.video_lambda.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function."
  value       = aws_lambda_function.video_lambda.arn
}

output "lambda_log_group" {
  description = "CloudWatch log group for Lambda. Query with: aws logs tail <group> --follow"
  value       = aws_cloudwatch_log_group.lambda_logs.name
}

output "lambda_dlq_url" {
  description = "SQS URL of the Lambda DLQ. Inspect failed invocations with: aws sqs receive-message --queue-url <url>"
  value       = aws_sqs_queue.lambda_dlq.url
}

# ── SQS intake ────────────────────────────────────────────────────────────────
output "intake_queue_url" {
  description = "SQS URL of the intake queue. S3 notifications are delivered here."
  value       = aws_sqs_queue.intake_queue.url
}

output "intake_queue_arn" {
  description = "ARN of the intake queue."
  value       = aws_sqs_queue.intake_queue.arn
}

# ── MediaConvert ──────────────────────────────────────────────────────────────
output "mediaconvert_queue_arn" {
  description = "ARN of the dedicated MediaConvert queue."
  value       = aws_media_convert_queue.dedicated.arn
}

output "mediaconvert_role_arn" {
  description = "ARN of the IAM role assumed by MediaConvert to read/write S3."
  value       = aws_iam_role.mediaconvert_role.arn
}

# ── DynamoDB ──────────────────────────────────────────────────────────────────
output "dedup_table_name" {
  description = "Name of the DynamoDB deduplication table."
  value       = aws_dynamodb_table.dedup.name
}

# ── SNS ───────────────────────────────────────────────────────────────────────
output "sns_topic_arn" {
  description = "ARN of the SNS topic that receives job completion and error notifications."
  value       = aws_sns_topic.mediaconvert_completion.arn
}

# ── Dashboard ─────────────────────────────────────────────────────────────────
output "dashboard_url" {
  description = "AWS Console URL for the CloudWatch pipeline dashboard."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.pipeline.dashboard_name}"
}
