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
