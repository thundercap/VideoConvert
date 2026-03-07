# ── SQS intake queue (#11) ─────────────────────────────────────────────────────
#
# Architecture: S3 → SQS intake queue → Lambda event source mapping → MediaConvert
#
# Why SQS in front of Lambda instead of direct S3 invocation:
#   - Configurable retry with backoff (maxReceiveCount before DLQ)
#   - Batch processing (up to 10 events per Lambda invocation)
#   - Partial batch failure support — only failed messages are retried
#   - Queue depth gives a natural backpressure metric
#   - Visibility timeout prevents duplicate processing during Lambda execution
#   - Message-level deduplication complements the DynamoDB dedup layer

resource "aws_sqs_queue" "intake_queue" {
  name = "${var.lambda_function_name}-intake"

  # Visibility timeout must be >= 6x Lambda timeout (AWS recommendation).
  # Lambda timeout = 60s  →  60 * 6 = 360s minimum.
  visibility_timeout_seconds = 360

  # Retain messages for 1 day; events older than that are too stale to transcode
  message_retention_seconds = 86400

  kms_master_key_id = "alias/aws/sqs"

  # After 3 failed processing attempts, move the message to the DLQ for inspection
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.lambda_dlq.arn
    maxReceiveCount     = 3
  })
}

# Allow S3 to publish to the intake queue.
# Source conditions prevent other accounts' S3 buckets from accidentally publishing here.
resource "aws_sqs_queue_policy" "intake_allow_s3" {
  queue_url = aws_sqs_queue.intake_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowS3SendMessage"
      Effect = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.intake_queue.arn
      Condition = {
        ArnLike    = { "aws:SourceArn"     = aws_s3_bucket.input_bucket.arn }
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

# Lambda reads from the intake queue via event source mapping.
# ReportBatchItemFailures means only failed messages are retried — successfully
# processed messages in the same batch are acknowledged immediately.
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.intake_queue.arn
  function_name    = aws_lambda_function.video_lambda.arn
  batch_size       = 10
  enabled          = true

  function_response_types = ["ReportBatchItemFailures"]

  # Cap the maximum concurrency the SQS poller can use.
  # This must be between 2 and 1000, and is a subset of reserved_concurrent_executions.
  dynamic "scaling_config" {
    for_each = var.lambda_reserved_concurrency >= 2 ? [1] : []
    content {
      maximum_concurrency = min(var.lambda_reserved_concurrency, 1000)
    }
  }
}

# Lambda execution role needs SQS read permissions to consume from the intake queue
resource "aws_iam_role_policy" "lambda_sqs_intake" {
  name = "lambda-sqs-intake-read"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
      ]
      Resource = aws_sqs_queue.intake_queue.arn
    }]
  })
}
