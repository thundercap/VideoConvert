resource "aws_s3_bucket" "video_bucket" {
  bucket = var.bucket_name
}

# IMPROVEMENT #7: Explicit public access block.
# Even though this bucket is private by intent, this resource explicitly enforces
# all four block settings so that no future ACL change or bucket policy can
# accidentally expose objects.
resource "aws_s3_bucket_public_access_block" "video_bucket_pab" {
  bucket = aws_s3_bucket.video_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "versioning" {
  bucket = aws_s3_bucket.video_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "encryption" {
  bucket = aws_s3_bucket.video_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# IMPROVEMENT #19: Lifecycle rule to expire raw uploaded videos after N days.
# Without this, every uploaded source file accumulates indefinitely in uploads/.
# Processed HLS output in processed/ is kept (no expiry).
resource "aws_s3_bucket_lifecycle_configuration" "lifecycle" {
  bucket = aws_s3_bucket.video_bucket.id

  rule {
    id     = "expire-raw-uploads"
    status = "Enabled"

    filter {
      prefix = "uploads/"
    }

    expiration {
      days = var.uploads_expiry_days
    }

    # Also clean up incomplete multipart uploads to avoid orphaned storage charges
    abort_incomplete_multipart_upload {
      days_after_initiation = 2
    }
  }
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.video_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.video_lambda.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "uploads/"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}
