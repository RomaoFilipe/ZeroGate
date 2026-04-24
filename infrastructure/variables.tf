variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Deployment environment (dev, staging, production)"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be dev, staging, or production."
  }
}

variable "project_name" {
  description = "Project name used to prefix all resources"
  type        = string
  default     = "zerogate"
}

variable "instance_type" {
  description = "EC2 instance type (t2.micro for free tier)"
  type        = string
  default     = "t2.micro"
}

variable "volume_size_gb" {
  description = "Root EBS volume size in GB (30 GB is free tier max)"
  type        = number
  default     = 30
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "availability_zone" {
  description = "Availability zone for the subnet (leave empty to auto-select)"
  type        = string
  default     = ""
}

variable "domain" {
  description = "Root domain name (e.g. yourdomain.com)"
  type        = string
}

variable "admin_email" {
  description = "Security/admin email for alerts"
  type        = string
}

variable "enable_guardduty" {
  description = "Enable AWS GuardDuty for threat detection"
  type        = bool
  default     = true
}

variable "enable_cloudtrail" {
  description = "Enable AWS CloudTrail for API auditing"
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = "Number of days to retain EBS snapshots"
  type        = number
  default     = 7
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  az          = var.availability_zone != "" ? var.availability_zone : "${var.aws_region}a"

  common_tags = {
    Domain = var.domain
  }
}
