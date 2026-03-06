terraform {
  # IMPROVEMENT #17: Pin the AWS provider version so a major version bump (e.g. v6)
  # can't silently break the configuration on the next `terraform init`.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  required_version = ">= 1.3"

  # IMPROVEMENT #18: Remote state backend — keeps terraform.tfstate in S3 with
  # DynamoDB locking so state is never lost and concurrent applies are serialised.
  # Uncomment and fill in your own bucket/table names before using in production.
  #
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
