resource "aws_cloudwatch_event_rule" "mediaconvert_complete" {
  name = "mediaconvert-job-complete"

  event_pattern = jsonencode({
    "source": ["aws.mediaconvert"],
    "detail-type": ["MediaConvert Job State Change"],
    "detail": {
      "status": ["COMPLETE", "ERROR"]
    }
  })
}

resource "aws_cloudwatch_event_target" "sns_target" {
  rule      = aws_cloudwatch_event_rule.mediaconvert_complete.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.mediaconvert_completion.arn
}

resource "aws_sns_topic_policy" "allow_eventbridge" {
  arn = aws_sns_topic.mediaconvert_completion.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
      Action   = "sns:Publish"
      Resource = aws_sns_topic.mediaconvert_completion.arn
    }]
  })
}

resource "aws_cloudwatch_metric_alarm" "lambda_error_alarm" {
  alarm_name          = "lambda-errors"
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
}

resource "aws_cloudwatch_metric_alarm" "mediaconvert_error_alarm" {
  alarm_name          = "mediaconvert-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "JobsErrored"
  namespace           = "AWS/MediaConvert"
  period              = 300
  statistic           = "Sum"
  threshold           = 0

  alarm_actions = [aws_sns_topic.mediaconvert_completion.arn]
}
