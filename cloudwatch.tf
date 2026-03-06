# IMPROVEMENT #5: Scope the EventBridge rule to only THIS pipeline's jobs by matching
# on the UserMetadata tag set in lambda_function.py. Previously the rule matched ALL
# MediaConvert jobs in the account — any other pipeline's completions/errors would have
# triggered your SNS alerts.
resource "aws_cloudwatch_event_rule" "mediaconvert_complete" {
  name        = "mediaconvert-job-complete"
  description = "Fires on COMPLETE or ERROR for jobs tagged pipeline=video-convert"

  event_pattern = jsonencode({
    source        = ["aws.mediaconvert"]
    "detail-type" = ["MediaConvert Job State Change"]
    detail = {
      status = ["COMPLETE", "ERROR"]
      userMetadata = {
        pipeline = ["video-convert"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "sns_target" {
  rule      = aws_cloudwatch_event_rule.mediaconvert_complete.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.mediaconvert_completion.arn
}

# IMPROVEMENT #9: Scope the SNS publish policy to this specific account and EventBridge
# rule ARN to prevent confused deputy attacks (another account's EventBridge publishing
# to our topic). Previously Principal was just "events.amazonaws.com" with no conditions.
resource "aws_sns_topic_policy" "allow_eventbridge" {
  arn = aws_sns_topic.mediaconvert_completion.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEventBridgePublish"
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action   = "sns:Publish"
      Resource = aws_sns_topic.mediaconvert_completion.arn
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnLike = {
          "aws:SourceArn" = aws_cloudwatch_event_rule.mediaconvert_complete.arn
        }
      }
    }]
  })
}

# ---------- Lambda Alarms ----------

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

  dimensions = {
    FunctionName = aws_lambda_function.video_lambda.function_name
  }

  alarm_actions = [aws_sns_topic.mediaconvert_completion.arn]
  # IMPROVEMENT #14: Notify on recovery so you know when the alarm has cleared
  ok_actions    = [aws_sns_topic.mediaconvert_completion.arn]
}

# IMPROVEMENT #15: Lambda throttle alarm — previously there was no visibility into
# concurrency being exhausted. If reserved_concurrent_executions is hit, Lambda
# silently throttles and the S3 event goes to the DLQ without any alert.
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

  dimensions = {
    FunctionName = aws_lambda_function.video_lambda.function_name
  }

  alarm_actions = [aws_sns_topic.mediaconvert_completion.arn]
  ok_actions    = [aws_sns_topic.mediaconvert_completion.arn]
}

# IMPROVEMENT #16: Lambda duration alarm — alerts before the 60s timeout is actually hit.
# Fires if the average execution time exceeds 50s in any 1-minute window.
resource "aws_cloudwatch_metric_alarm" "lambda_duration_alarm" {
  alarm_name          = "lambda-duration-high"
  alarm_description   = "Lambda average duration exceeded 50s — approaching the 60s timeout"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Average"
  threshold           = 50000 # milliseconds

  dimensions = {
    FunctionName = aws_lambda_function.video_lambda.function_name
  }

  alarm_actions = [aws_sns_topic.mediaconvert_completion.arn]
  ok_actions    = [aws_sns_topic.mediaconvert_completion.arn]
}

# ---------- MediaConvert Alarm ----------

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

  alarm_actions = [aws_sns_topic.mediaconvert_completion.arn]
  # IMPROVEMENT #14: ok_actions on MediaConvert alarm too
  ok_actions    = [aws_sns_topic.mediaconvert_completion.arn]
}
