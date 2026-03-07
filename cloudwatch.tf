# ── EventBridge rule — scoped to this pipeline only ───────────────────────────
resource "aws_cloudwatch_event_rule" "mediaconvert_complete" {
  name        = "mediaconvert-job-complete"
  description = "Fires on COMPLETE or ERROR for jobs tagged pipeline=video-convert"

  event_pattern = jsonencode({
    source        = ["aws.mediaconvert"]
    "detail-type" = ["MediaConvert Job State Change"]
    detail = {
      status = ["COMPLETE", "ERROR"]
      userMetadata = { pipeline = ["video-convert"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "sns_target" {
  rule      = aws_cloudwatch_event_rule.mediaconvert_complete.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.mediaconvert_completion.arn
}

# SNS topic policy — scoped to this account and specific EventBridge rule
resource "aws_sns_topic_policy" "allow_eventbridge" {
  arn = aws_sns_topic.mediaconvert_completion.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEventBridgePublish"
      Effect = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action   = "sns:Publish"
      Resource = aws_sns_topic.mediaconvert_completion.arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn"     = aws_cloudwatch_event_rule.mediaconvert_complete.arn }
      }
    }]
  })
}

# ── CloudWatch Log Group (#5) ──────────────────────────────────────────────────
# Explicitly managing the log group lets us set a retention period — without this,
# Lambda auto-creates one with infinite retention and logs accrue unbounded cost.
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${var.lambda_function_name}"
  retention_in_days = var.log_retention_days
}

# ── Lambda alarms ─────────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "lambda_error_alarm" {
  alarm_name          = "lambda-errors"
  alarm_description   = "Lambda function produced one or more errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.video_lambda.function_name }
  alarm_actions       = [aws_sns_topic.mediaconvert_completion.arn]
  ok_actions          = [aws_sns_topic.mediaconvert_completion.arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttle_alarm" {
  alarm_name          = "lambda-throttles"
  alarm_description   = "Lambda is being throttled — concurrency limit may be too low"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.video_lambda.function_name }
  alarm_actions       = [aws_sns_topic.mediaconvert_completion.arn]
  ok_actions          = [aws_sns_topic.mediaconvert_completion.arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_duration_alarm" {
  alarm_name          = "lambda-duration-high"
  alarm_description   = "Lambda average duration > 50s — approaching the 60s timeout"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Average"
  threshold           = 50000  # milliseconds
  treat_missing_data  = "notBreaching"
  dimensions          = { FunctionName = aws_lambda_function.video_lambda.function_name }
  alarm_actions       = [aws_sns_topic.mediaconvert_completion.arn]
  ok_actions          = [aws_sns_topic.mediaconvert_completion.arn]
}

resource "aws_cloudwatch_metric_alarm" "mediaconvert_error_alarm" {
  alarm_name          = "mediaconvert-errors"
  alarm_description   = "One or more MediaConvert jobs for this pipeline errored"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "JobsErrored"
  namespace           = "AWS/MediaConvert"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.mediaconvert_completion.arn]
  ok_actions          = [aws_sns_topic.mediaconvert_completion.arn]
}

resource "aws_cloudwatch_metric_alarm" "dlq_depth_alarm" {
  alarm_name          = "lambda-dlq-messages"
  alarm_description   = "Messages in the Lambda DLQ — investigate failed invocations"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = aws_sqs_queue.lambda_dlq.name }
  alarm_actions       = [aws_sns_topic.mediaconvert_completion.arn]
  ok_actions          = [aws_sns_topic.mediaconvert_completion.arn]
}

# ── CloudWatch Dashboard (#15) ────────────────────────────────────────────────
# Single pane of glass showing Lambda health, MediaConvert throughput,
# queue depths, and custom pipeline metrics side by side.
resource "aws_cloudwatch_dashboard" "pipeline" {
  dashboard_name = "VideoConvert-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x = 0; y = 0; width = 12; height = 6
        properties = {
          title  = "Lambda — Invocations / Errors / Throttles"
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.lambda_function_name],
            ["AWS/Lambda", "Errors",      "FunctionName", var.lambda_function_name],
            ["AWS/Lambda", "Throttles",   "FunctionName", var.lambda_function_name],
          ]
        }
      },
      {
        type   = "metric"
        x = 12; y = 0; width = 12; height = 6
        properties = {
          title  = "Lambda — Duration p50 / p99"
          view   = "timeSeries"
          period = 60
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", var.lambda_function_name, { stat = "p50" }],
            ["AWS/Lambda", "Duration", "FunctionName", var.lambda_function_name, { stat = "p99" }],
          ]
        }
      },
      {
        type   = "metric"
        x = 0; y = 6; width = 12; height = 6
        properties = {
          title  = "MediaConvert — Jobs Completed / Errored"
          view   = "timeSeries"
          period = 300
          stat   = "Sum"
          metrics = [
            ["AWS/MediaConvert", "JobsCompletedCount", "Queue", "video-convert"],
            ["AWS/MediaConvert", "JobsErroredCount",   "Queue", "video-convert"],
          ]
        }
      },
      {
        type   = "metric"
        x = 12; y = 6; width = 12; height = 6
        properties = {
          title  = "Pipeline Throughput — Submitted / Deduplicated"
          view   = "timeSeries"
          period = 300
          stat   = "Sum"
          metrics = [
            ["VideoConvert", "JobsSubmitted",    "Pipeline", "video-convert"],
            ["VideoConvert", "JobsDeduplicated", "Pipeline", "video-convert"],
          ]
        }
      },
      {
        type   = "metric"
        x = 0; y = 12; width = 24; height = 6
        properties = {
          title  = "Queue Depths — Intake / DLQ"
          view   = "timeSeries"
          period = 60
          stat   = "Maximum"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "${var.lambda_function_name}-intake"],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "${var.lambda_function_name}-dlq"],
          ]
        }
      },
    ]
  })
}
