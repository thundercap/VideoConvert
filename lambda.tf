data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

resource "aws_lambda_function" "video_lambda" {
  function_name    = var.lambda_function_name
  role             = aws_iam_role.lambda_role.arn
  runtime          = "python3.9"
  handler          = "lambda_function.lambda_handler"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      BUCKET_NAME            = aws_s3_bucket.video_bucket.bucket
      MEDIACONVERT_ROLE      = aws_iam_role.mediaconvert_role.arn
      REGION                 = var.region
      # FIX: MEDIACONVERT_QUEUE was read by lambda_function.py but never passed in —
      # would cause a silent fallback to "Default" at best; passing it explicitly now.
      MEDIACONVERT_QUEUE     = var.mediaconvert_queue
      # FIX: MEDIACONVERT_ENDPOINT was read by lambda_function.py but never passed in —
      # without it the function rediscovers the endpoint on every cold start (extra API call).
      MEDIACONVERT_ENDPOINT  = var.mediaconvert_endpoint
    }
  }
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.video_lambda.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.video_bucket.arn
}
