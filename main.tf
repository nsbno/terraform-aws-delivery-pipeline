terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = ">= 4.9.0"
    }
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
