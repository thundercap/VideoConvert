resource "aws_iam_role" "lambda_role" {
  name = "lambda-mediaconvert-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# IMPROVEMENT #13: Attach X-Ray write permissions so active tracing works
resource "aws_iam_role_policy_attachment" "lambda_xray" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_policy" "lambda_policy" {
  name = "lambda-mediaconvert-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "mediaconvert:CreateJob",
          "mediaconvert:DescribeEndpoints"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["s3:GetObject"]
        # Scoped only to uploads/ — Lambda never needs to read processed/ or bucket root
        Resource = "${aws_s3_bucket.video_bucket.arn}/uploads/*"
      },
      {
        Effect = "Allow"
        Action = ["s3:HeadObject"]
        # IMPROVEMENT #22: HeadObject needed for the zero-byte file size guard
        Resource = "${aws_s3_bucket.video_bucket.arn}/uploads/*"
      },
      {
        Effect = "Allow"
        Action = ["iam:PassRole"]
        # Scoped tightly to the MediaConvert role ARN only — not iam:PassRole on *
        Resource = aws_iam_role.mediaconvert_role.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_custom" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}
