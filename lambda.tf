data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

# Dead Letter Queue — captures Lambda async invocation failures
# (SQS-triggered invocations use the intake queue's own redrive policy instead)
resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "${var.lambda_function_name}-dlq"
  message_retention_seconds = 1209600  # 14 days — maximum SQS retention
  kms_master_key_id         = "alias/aws/sqs"
}

resource "aws_lambda_function" "video_lambda" {
  function_name    = var.lambda_function_name
  role             = aws_iam_role.lambda_role.arn
  runtime          = "python3.12"
  handler          = "lambda_function.lambda_handler"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 60
  memory_size      = 128

  # (#3) ARM64 / Graviton2 — ~20% cheaper per GB-second than x86 for the same
  # workload with no code changes required. This function is API-only so the
  # architecture switch has zero observable effect on behaviour.
  architectures = ["arm64"]

  reserved_concurrent_executions = var.lambda_reserved_concurrency

  tracing_config {
    mode = "Active"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }

  environment {
    variables = {
      BUCKET_NAME            = aws_s3_bucket.input_bucket.bucket
      OUTPUT_BUCKET          = aws_s3_bucket.output_bucket.bucket   # (#9) separate output bucket
      MEDIACONVERT_ROLE      = aws_iam_role.mediaconvert_role.arn
      REGION                 = var.region
      # (#4) Default to the dedicated queue; override with var.mediaconvert_queue if set
      MEDIACONVERT_QUEUE     = var.mediaconvert_queue != "" ? var.mediaconvert_queue : aws_media_convert_queue.dedicated.arn
      MEDIACONVERT_ENDPOINT  = var.mediaconvert_endpoint
      DEDUP_TABLE            = aws_dynamodb_table.dedup.name        # (#6)
      # (#7) Uses the Terraform-managed job template by default; override by setting
      # var.job_template_arn to an existing ARN, or set it to "" to use inline settings.
      JOB_TEMPLATE_ARN       = local.effective_job_template_arn
      STATUS_UPDATE_INTERVAL = var.status_update_interval           # (#17)
      DEDUP_TTL_SECONDS      = tostring(var.dedup_ttl_hours * 3600) # (#6)
    }
  }
}

# Note: aws_lambda_permission.allow_s3 removed — S3 no longer invokes Lambda
# directly. S3 → SQS intake queue → Lambda event source mapping (see sqs_intake.tf). (#11)

# Allow Lambda execution role to send failed async invocations to the DLQ
resource "aws_iam_role_policy" "lambda_dlq_policy" {
  name = "lambda-dlq-send"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.lambda_dlq.arn
    }]
  })
}
