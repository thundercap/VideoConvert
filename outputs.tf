# IMPROVEMENT #20: Expanded outputs — previously only bucket_name and lambda_name
# were exported. These additions make it easy to reference this module from other
# stacks, run CLI commands, and debug issues without digging through the console.

output "bucket_name" {
  description = "Name of the S3 bucket used for video ingestion and HLS output."
  value       = aws_s3_bucket.video_bucket.bucket
}

output "bucket_arn" {
  description = "ARN of the S3 video bucket."
  value       = aws_s3_bucket.video_bucket.arn
}

output "lambda_function_name" {
  description = "Name of the Lambda function that triggers MediaConvert jobs."
  value       = aws_lambda_function.video_lambda.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function."
  value       = aws_lambda_function.video_lambda.arn
}

output "lambda_log_group" {
  description = "CloudWatch log group for Lambda function logs."
  value       = "/aws/lambda/${aws_lambda_function.video_lambda.function_name}"
}

output "lambda_dlq_url" {
  description = "SQS URL of the Lambda Dead Letter Queue for inspecting failed invocations."
  value       = aws_sqs_queue.lambda_dlq.url
}

output "mediaconvert_role_arn" {
  description = "ARN of the IAM role assumed by MediaConvert to read/write S3."
  value       = aws_iam_role.mediaconvert_role.arn
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic that receives job completion and error notifications."
  value       = aws_sns_topic.mediaconvert_completion.arn
}
