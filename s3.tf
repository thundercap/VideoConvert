resource "aws_s3_bucket" "video_bucket" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.video_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.video_lambda.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "uploads/"
  }

  depends_on = [
    aws_lambda_permission.allow_s3
  ]
}
