terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = ">= 4.9.0"
    }
    vy = {
      source = "nsbno/vy"
      version = ">= 0.3.1"
    }
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
