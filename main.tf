terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  required_version = ">= 1.3"

  # Remote state backend — uncomment for production.
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "videoconvert/terraform.tfstate"
  #   region         = "ap-south-1"
  #   dynamodb_table = "terraform-state-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "VideoConvert"
      ManagedBy   = "Terraform"
      Environment = var.environment
    }
  }
}

data "aws_caller_identity" "current" {}

# ── Locals ────────────────────────────────────────────────────────────────────
# Resolve the effective job template ARN (#7):
#   - If the user provides an explicit var.job_template_arn, use that (e.g. an
#     existing template from another stack or a manually tuned one).
#   - Otherwise use the template created by this configuration so that Lambda
#     always delegates encoding settings to MediaConvert rather than its own code.
locals {
  effective_job_template_arn = var.job_template_arn != "" ? var.job_template_arn : aws_media_convert_job_template.hls_abr.arn
}
