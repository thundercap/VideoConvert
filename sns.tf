# IMPROVEMENT #8: Encrypt the SNS topic at rest using the AWS-managed SNS KMS key.
# Job completion messages carry bucket paths and file names — encrypting them costs
# nothing extra and satisfies security best-practice requirements.
resource "aws_sns_topic" "mediaconvert_completion" {
  name              = "mediaconvert-job-completion"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.mediaconvert_completion.arn
  protocol  = "email"
  endpoint  = var.notification_email
}
