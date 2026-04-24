terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }

  # Remote state backend — activated by: make backend-init
  # That script creates the S3 bucket + DynamoDB table and writes this block.
  # Do not edit manually — run make backend-init instead.
  #
  # backend "s3" {
  #   bucket         = "zerogate-tfstate-<ACCOUNT_ID>"   # filled by make backend-init
  #   key            = "zerogate/terraform.tfstate"
  #   region         = "eu-west-1"
  #   dynamodb_table = "zerogate-tfstate-lock"
  #   encrypt        = true
  # }
}

provider "cloudflare" {
  api_token = var.cf_api_token
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "ZeroGate"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
