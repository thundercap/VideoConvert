# ── Existing variables (with validation improvements) ─────────────────────────

variable "region" {
  description = "AWS region to deploy all resources into."
  type        = string
  default     = "ap-south-1"

  validation {
    condition     = can(regex("^[a-z]{2,3}(-[a-z0-9]+)+-[0-9]{1,2}$", var.region))
    error_message = "region must be a valid AWS region string, e.g. 'ap-south-1', 'us-gov-west-1'."
  }
}

variable "environment" {
  description = "Deployment environment label used in resource tags."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "bucket_name" {
  description = "Name of the S3 input bucket — receives raw uploaded videos."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9\\-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 chars, lowercase alphanumeric and hyphens only."
  }
}

variable "output_bucket_name" {
  description = <<-EOT
    Name of the separate S3 output bucket — MediaConvert writes HLS output here. (#9)
    Must differ from bucket_name. Keeping input and output in separate buckets lets
    you independently control versioning, lifecycle rules, and access policies.
  EOT
  type = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9\\-]{1,61}[a-z0-9]$", var.output_bucket_name))
    error_message = "output_bucket_name must be 3-63 chars, lowercase alphanumeric and hyphens only."
  }
}

variable "lambda_function_name" {
  description = "Name for the Lambda function that triggers MediaConvert jobs."
  type        = string
  default     = "video-transcode-lambda"
}

variable "notification_email" {
  description = "Email address for MediaConvert job completion / error notifications via SNS."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.notification_email))
    error_message = "notification_email must be a valid email address."
  }
}

variable "mediaconvert_queue" {
  description = <<-EOT
    MediaConvert queue ARN or name. Leave empty to use the dedicated queue created by
    this module (recommended). Set to "Default" to use the shared account-default queue,
    or provide a custom ARN to use an existing queue.
  EOT
  type    = string
  default = ""  # Empty = use aws_media_convert_queue.dedicated
}

variable "mediaconvert_endpoint" {
  description = <<-EOT
    MediaConvert regional endpoint URL. Providing this skips the DescribeEndpoints
    API call on every Lambda cold start. Leave empty to auto-discover.
    Example: "https://xxxxxxxx.mediaconvert.ap-south-1.amazonaws.com"
  EOT
  type    = string
  default = ""
}

variable "job_template_arn" {
  description = <<-EOT
    ARN of an existing MediaConvert Job Template to use for encoding. (#7)
    When set, Lambda sends only the Input and output Destination to MediaConvert —
    all codec / bitrate / segment settings are read from the template, making
    encoding changes possible without Lambda redeployment.
    Leave empty to use the inline ABR settings built into the Lambda function.
  EOT
  type    = string
  default = ""
}

variable "status_update_interval" {
  description = <<-EOT
    How often MediaConvert sends progress events to EventBridge. (#17)
    Choices: SECONDS_10 | SECONDS_12 | SECONDS_15 | SECONDS_20 | SECONDS_30 | SECONDS_60
    Use a shorter interval for short clips where you want live progress.
    Use SECONDS_60 (default) for long-form content to reduce EventBridge event volume.
  EOT
  type    = string
  default = "SECONDS_60"

  validation {
    condition = contains([
      "SECONDS_10", "SECONDS_12", "SECONDS_15",
      "SECONDS_20", "SECONDS_30", "SECONDS_60"
    ], var.status_update_interval)
    error_message = "status_update_interval must be one of the supported MediaConvert intervals."
  }
}

variable "uploads_expiry_days" {
  description = "Days after which raw uploaded source videos in uploads/ are deleted. (#1)"
  type        = number
  default     = 7

  validation {
    condition     = var.uploads_expiry_days >= 1 && var.uploads_expiry_days <= 365
    error_message = "uploads_expiry_days must be between 1 and 365."
  }
}

variable "processed_expiry_days" {
  description = <<-EOT
    Days after which HLS output in the output bucket is deleted. (#2)
    Set to 0 to keep output indefinitely. Defaults to 90 days.
  EOT
  type    = number
  default = 90

  validation {
    condition     = var.processed_expiry_days >= 0 && var.processed_expiry_days <= 3650
    error_message = "processed_expiry_days must be between 0 (no expiry) and 3650."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period for Lambda logs in days. (#5)"
  type        = number
  default     = 30

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 3653
    ], var.log_retention_days)
    error_message = "log_retention_days must be a value accepted by CloudWatch Logs."
  }
}

variable "lambda_reserved_concurrency" {
  description = <<-EOT
    Reserved concurrency limit for Lambda. Caps simultaneous MediaConvert job submissions.
    Set to -1 to use the unreserved pool. Minimum 2 when using SQS event source mapping.
  EOT
  type    = number
  default = 10

  validation {
    condition     = var.lambda_reserved_concurrency == -1 || var.lambda_reserved_concurrency >= 2
    error_message = "lambda_reserved_concurrency must be -1 (unreserved) or >= 2."
  }
}

variable "dedup_ttl_hours" {
  description = <<-EOT
    How long (hours) a job claim is held in DynamoDB before expiring. (#6)
    Within this window, duplicate S3 event deliveries for the same upload are suppressed.
    Re-uploads of the same filename bypass dedup because they have a different eTag.
  EOT
  type    = number
  default = 24

  validation {
    condition     = var.dedup_ttl_hours >= 1 && var.dedup_ttl_hours <= 168
    error_message = "dedup_ttl_hours must be between 1 and 168 (1 week)."
  }
}

variable "enable_cloudfront" {
  description = <<-EOT
    Create a CloudFront distribution in front of the output bucket. (#12)
    Strongly recommended for any real delivery use case — reduces S3 GET costs,
    lowers viewer latency, and enforces HTTPS.
  EOT
  type    = bool
  default = true
}

variable "cloudfront_price_class" {
  description = <<-EOT
    CloudFront price class controlling which edge locations are used. (#12)
    PriceClass_100 = North America + Europe (cheapest).
    PriceClass_200 = + Asia Pacific, Middle East, Africa.
    PriceClass_All = all edge locations (most expensive, lowest latency globally).
  EOT
  type    = string
  default = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.cloudfront_price_class)
    error_message = "cloudfront_price_class must be PriceClass_100, PriceClass_200, or PriceClass_All."
  }
}
