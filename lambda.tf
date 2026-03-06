data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

# IMPROVEMENT #10: SQS Dead Letter Queue.
# S3 event notifications invoke Lambda asynchronously. If Lambda fails after
# AWS's built-in retries, the event is normally silently dropped. The DLQ captures
# those failed events so they can be inspected and replayed.
resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "${var.lambda_function_name}-dlq"
  message_retention_seconds = 1209600 # 14 days — maximum retention
}

resource "aws_lambda_function" "video_lambda" {
  function_name    = var.lambda_function_name
  role             = aws_iam_role.lambda_role.arn

  # IMPROVEMENT #6: Upgraded from deprecated python3.9 to python3.12.
  runtime          = "python3.12"
  handler          = "lambda_function.lambda_handler"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 60

  # IMPROVEMENT #23: Explicit memory size. 128MB is appropriate for an API-only function
  # (no video data moves through Lambda), but documenting it makes future tuning deliberate.
  memory_size = 128

  # IMPROVEMENT #11: Reserved concurrency cap.
  # Prevents a sudden upload spike from spawning unbounded Lambda instances that
  # hammer the MediaConvert CreateJob API. -1 means use unreserved pool.
  reserved_concurrent_executions = var.lambda_reserved_concurrency

  # IMPROVEMENT #13: X-Ray active tracing for end-to-end visibility into cold starts
  # and downstream MediaConvert API call latency.
  tracing_config {
    mode = "Active"
  }

  # IMPROVEMENT #10: Wire the DLQ so failed async invocations land here
  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }

  environment {
    variables = {
      BUCKET_NAME           = aws_s3_bucket.video_bucket.bucket
      MEDIACONVERT_ROLE     = aws_iam_role.mediaconvert_role.arn
      REGION                = var.region
      MEDIACONVERT_QUEUE    = var.mediaconvert_queue
      MEDIACONVERT_ENDPOINT = var.mediaconvert_endpoint
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

# IMPROVEMENT #10: Allow Lambda to send messages to the DLQ
resource "aws_iam_role_policy" "lambda_dlq_policy" {
  name = "lambda-dlq-send"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.lambda_dlq.arn
    }]
  })
}
