terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region              = "eu-west-1"
  allowed_account_ids = [455398910694]
}

locals {
  name_prefix        = "deployer-example"
  service_account_id = 689783162268
}

/*
 *  == Allow the pipeline to deploy our resources
 *
 *  This role allows us to deploy resources from the service account.
 *  It is required in all deployment accounts for the module to work.
 */

module "deployment_pipeline_permissions" {
  source = "../../../extras/permissions"

  name_prefix        = "deployment"
  service_account_id = local.service_account_id
}
