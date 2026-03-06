variable "region" {
  description = "AWS region to deploy all resources into."
  type        = string
  default     = "ap-south-1"

  # IMPROVEMENT #21: Validate variable values at `terraform validate` time rather
  # than waiting for a deep AWS API error at `terraform apply`.
  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.region))
    error_message = "region must be a valid AWS region string, e.g. 'ap-south-1'."
  }
}

variable "environment" {
  description = "Deployment environment label used in resource tags (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name for video ingestion and output storage."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9\\-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 chars, lowercase alphanumeric and hyphens only, and cannot start/end with a hyphen."
  }
}

variable "lambda_function_name" {
  description = "Name for the Lambda function that triggers MediaConvert jobs."
  type        = string
  default     = "video-transcode-lambda"
}

variable "notification_email" {
  description = "Email address that receives MediaConvert job completion and error notifications via SNS."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.notification_email))
    error_message = "notification_email must be a valid email address."
  }
}

# IMPROVEMENT #17 (previously added): Explicit queue variable wired to Lambda env
variable "mediaconvert_queue" {
  description = "MediaConvert queue ARN or name. Use 'Default' for the account default queue."
  type        = string
  default     = "Default"
}

# IMPROVEMENT #17 (previously added): Optional endpoint to skip cold-start discovery
variable "mediaconvert_endpoint" {
  description = <<-EOT
    MediaConvert regional endpoint URL. Providing this skips the DescribeEndpoints
    API call on every Lambda cold start. Leave as empty string to auto-discover.
    Example: "https://xxxxxxxx.mediaconvert.ap-south-1.amazonaws.com"
  EOT
  type    = string
  default = ""
}

variable "uploads_expiry_days" {
  description = "Number of days after which raw uploaded videos in uploads/ are automatically deleted."
  type        = number
  default     = 7

  # IMPROVEMENT #19: Lifecycle rule variable — keeps cost under control automatically
  validation {
    condition     = var.uploads_expiry_days >= 1 && var.uploads_expiry_days <= 365
    error_message = "uploads_expiry_days must be between 1 and 365."
  }
}

variable "lambda_reserved_concurrency" {
  description = <<-EOT
    Reserved concurrency limit for the Lambda function. Caps how many simultaneous
    MediaConvert jobs can be submitted at once. Set to -1 to use unreserved concurrency.
  EOT
  type    = number
  default = 10

  # IMPROVEMENT #11: Concurrency cap variable
  validation {
    condition     = var.lambda_reserved_concurrency == -1 || var.lambda_reserved_concurrency >= 1
    error_message = "lambda_reserved_concurrency must be -1 (unreserved) or a positive integer."
  }
}
