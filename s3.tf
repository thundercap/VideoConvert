# ── Input bucket ───────────────────────────────────────────────────────────────
# Receives raw video uploads. Versioning is intentionally enabled here so that
# accidental overwrites of source files are recoverable.

resource "aws_s3_bucket" "input_bucket" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "input_bucket_pab" {
  bucket                  = aws_s3_bucket.input_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "input_versioning" {
  bucket = aws_s3_bucket.input_bucket.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "input_encryption" {
  bucket = aws_s3_bucket.input_bucket.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "input_lifecycle" {
  bucket = aws_s3_bucket.input_bucket.id

  rule {
    id     = "expire-raw-uploads"
    status = "Enabled"

    filter { prefix = "uploads/" }

    expiration { days = var.uploads_expiry_days }

    # Without this, versioning keeps every old copy of the file indefinitely even
    # after the current version expires — negating the cost-control goal.
    noncurrent_version_expiration { noncurrent_days = var.uploads_expiry_days }

    abort_incomplete_multipart_upload { days_after_initiation = 2 }
  }
}

# (#11) S3 now notifies the SQS intake queue instead of invoking Lambda directly.
# The depends_on ensures the queue policy is in place before S3 starts publishing.
resource "aws_s3_bucket_notification" "input_notification" {
  bucket = aws_s3_bucket.input_bucket.id

  queue {
    queue_arn     = aws_sqs_queue.intake_queue.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "uploads/"
  }

  depends_on = [aws_sqs_queue_policy.intake_allow_s3]
}


# ── Output bucket (#9) ─────────────────────────────────────────────────────────
# Receives MediaConvert HLS output. Kept separate from the input bucket so that:
#   - Versioning can be disabled (HLS segments are written once, never modified)
#   - Lifecycle and storage class rules are independent
#   - IAM boundary between upload ingestion and transcoded output is explicit

resource "aws_s3_bucket" "output_bucket" {
  bucket = var.output_bucket_name
}

resource "aws_s3_bucket_public_access_block" "output_bucket_pab" {
  bucket                  = aws_s3_bucket.output_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# No versioning on output — HLS segments are immutable write-once objects.
# Enabling versioning here would double storage cost with zero recovery benefit.
resource "aws_s3_bucket_versioning" "output_versioning" {
  bucket = aws_s3_bucket.output_bucket.id
  versioning_configuration { status = "Disabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "output_encryption" {
  bucket = aws_s3_bucket.output_bucket.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# (#10) S3 Intelligent-Tiering — automatically moves objects to cheaper storage
# tiers (Standard-IA at 30 days, Archive Instant Access at 90 days) based on
# access patterns, with no retrieval fees. HLS output is accessed heavily right
# after encoding then rarely — this can cut output storage cost by 40-60% over time.
resource "aws_s3_bucket_intelligent_tiering_configuration" "output_tiering" {
  bucket = aws_s3_bucket.output_bucket.id
  name   = "whole-bucket"

  tiering {
    access_tier = "ARCHIVE_INSTANT_ACCESS"
    days        = 90
  }
}

# (#2) Lifecycle expiry — processed HLS output is deleted after N days.
# Without this, every transcoded file accumulates indefinitely.
resource "aws_s3_bucket_lifecycle_configuration" "output_lifecycle" {
  count  = var.processed_expiry_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.output_bucket.id

  rule {
    id     = "expire-processed-output"
    status = "Enabled"

    filter { prefix = "processed/" }

    expiration { days = var.processed_expiry_days }

    abort_incomplete_multipart_upload { days_after_initiation = 2 }
  }
}
