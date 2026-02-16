resource "aws_iam_role" "mediaconvert_role" {
  name = "mediaconvert-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "mediaconvert.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_policy" "mediaconvert_s3_policy" {
  name = "mediaconvert-s3-access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.video_bucket.arn}/uploads/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.video_bucket.arn}/processed/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "mediaconvert_custom_attach" {
  role       = aws_iam_role.mediaconvert_role.name
  policy_arn = aws_iam_policy.mediaconvert_s3_policy.arn
}
