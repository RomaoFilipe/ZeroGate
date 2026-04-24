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
  }

  # Uncomment after creating the S3 bucket and DynamoDB table manually (one-time):
  #   aws s3api create-bucket --bucket zerogate-tfstate-<ACCOUNT_ID> \
  #     --region eu-west-1 --create-bucket-configuration LocationConstraint=eu-west-1
  #   aws s3api put-bucket-versioning --bucket zerogate-tfstate-<ACCOUNT_ID> \
  #     --versioning-configuration Status=Enabled
  #   aws s3api put-bucket-encryption --bucket zerogate-tfstate-<ACCOUNT_ID> \
  #     --server-side-encryption-configuration \
  #     '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  #   aws dynamodb create-table --table-name zerogate-tfstate-lock \
  #     --attribute-definitions AttributeName=LockID,AttributeType=S \
  #     --key-schema AttributeName=LockID,KeyType=HASH \
  #     --billing-mode PAY_PER_REQUEST --region eu-west-1

  # backend "s3" {
  #   bucket         = "zerogate-tfstate-<ACCOUNT_ID>"
  #   key            = "zerogate/terraform.tfstate"
  #   region         = "eu-west-1"
  #   dynamodb_table = "zerogate-tfstate-lock"
  #   encrypt        = true
  # }
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
