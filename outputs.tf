output "bucket_name" {
  value = aws_s3_bucket.video_bucket.bucket
}

output "lambda_name" {
  value = aws_lambda_function.video_lambda.function_name
}
