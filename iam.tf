resource "aws_iam_role" "lambda_role" {
  name = "lambda-mediaconvert-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

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
        # MediaConvert job submission and endpoint discovery
        Effect   = "Allow"
        Action   = ["mediaconvert:CreateJob", "mediaconvert:DescribeEndpoints"]
        Resource = "*"
      },
      {
        # (#9) Read from input bucket only; s3:GetObject also covers HeadObject requests
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.input_bucket.arn}/uploads/*"
      },
      {
        # PassRole scoped tightly to the MediaConvert service role only
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.mediaconvert_role.arn
      },
      {
        # (#6) DynamoDB conditional put for job deduplication
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.dedup.arn
      },
      {
        # (#16) Custom pipeline throughput metrics in the VideoConvert namespace
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "VideoConvert" }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_custom" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}
