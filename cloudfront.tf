# ── CloudFront HLS delivery (#12) ──────────────────────────────────────────────
#
# Why CloudFront in front of the output bucket:
#   - Caches HLS segments (.ts) at edge — dramatically reduces S3 GET requests and costs
#   - Global low-latency delivery for video players worldwide
#   - Enforces HTTPS — S3 pre-signed URLs over HTTP become unnecessary
#   - Origin Shield reduces origin load during simultaneous viewer spikes
#   - Signed URLs / signed cookies can be added later for access control
#
# HLS manifest files (.m3u8) get a separate cache behavior with a much shorter TTL
# because players need to fetch updated playlists as segments are written.

resource "aws_cloudfront_origin_access_control" "output_oac" {
  count = var.enable_cloudfront ? 1 : 0

  name                              = "${var.output_bucket_name}-oac"
  description                       = "OAC for VideoConvert output bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "hls_cdn" {
  count = var.enable_cloudfront ? 1 : 0

  enabled     = true
  comment     = "VideoConvert HLS delivery — ${var.environment}"
  price_class = var.cloudfront_price_class

  origin {
    domain_name              = aws_s3_bucket.output_bucket.bucket_regional_domain_name
    origin_id                = "s3-output"
    origin_access_control_id = aws_cloudfront_origin_access_control.output_oac[0].id
  }

  # HLS manifest files — short TTL (60 s) so players get updated playlists promptly.
  # Manifests are small and change frequently during active transcoding.
  ordered_cache_behavior {
    path_pattern     = "*.m3u8"
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "s3-output"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    # AWS managed CachingDisabled policy — passes all requests to origin
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
  }

  # HLS segment files (.ts) — long cache; segments are immutable once written.
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-output"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    # AWS managed CachingOptimized policy — long TTL, compression enabled
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Bucket policy — only CloudFront OAC can read from the output bucket.
# Viewers cannot access S3 directly, enforcing all traffic through CloudFront.
resource "aws_s3_bucket_policy" "output_cloudfront_policy" {
  count  = var.enable_cloudfront ? 1 : 0
  bucket = aws_s3_bucket.output_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCloudFrontRead"
      Effect = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action   = "s3:GetObject"
      Resource = "${aws_s3_bucket.output_bucket.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.hls_cdn[0].arn
        }
      }
    }]
  })
}
