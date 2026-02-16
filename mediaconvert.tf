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

resource "aws_iam_role_policy_attachment" "mediaconvert_s3_access" {
  role       = aws_iam_role.mediaconvert_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}
