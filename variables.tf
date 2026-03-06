variable "region" {
  default = "ap-south-1"
}

variable "bucket_name" {
  description = "Unique S3 bucket name"
  type        = string
}

variable "lambda_function_name" {
  default = "video-transcode-lambda"
}

variable "notification_email" {
  type = string
}

# FIX: Added to match MEDIACONVERT_QUEUE env var read by lambda_function.py
variable "mediaconvert_queue" {
  description = "MediaConvert queue name (use 'Default' for the default queue)"
  type        = string
  default     = "Default"
}

# FIX: Added to match MEDIACONVERT_ENDPOINT env var read by lambda_function.py.
# Providing this avoids a DescribeEndpoints API call on every Lambda cold start.
# Leave empty ("") to let the Lambda discover it automatically.
variable "mediaconvert_endpoint" {
  description = "MediaConvert regional endpoint URL. Leave empty to auto-discover."
  type        = string
  default     = ""
}
