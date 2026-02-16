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
