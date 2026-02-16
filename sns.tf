resource "aws_sns_topic" "mediaconvert_completion" {
  name = "mediaconvert-job-completion"
}

resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.mediaconvert_completion.arn
  protocol  = "email"
  endpoint  = var.notification_email
}
