terraform {
    required_version = "1.0.0"

    required_providers {
        aws = {
            source = "hashicorp/aws"
            version = "~> 3.0"
        }
    }
}

provider "aws" {
    region = "eu-west-1"
    allowed_account_ids = [689783162268]
}

locals {
    name_prefix = "deployer-example"
    service_account_id = 689783162268
}

# Get some existing subnets from infrademo
data "aws_subnet_ids" "subnets" {
    vpc_id = "vpc-088edf3000b91734f"

    tags = {
        type = "public"
    }
}

/*
 * == Create the deployment pipeline
 *
 * This is the boilerplate for creating the deployment pipeline.
 */
module "deploymet_pipeline" {
    source = "../../../"

    name_prefix = local.name_prefix
    deployment_accounts = [
        # Infrademo accounts
        689783162268,  # Service
        061938725231,  # Test
        455398910694,  # Stage
        184682413771,  # Prod
    ]
    deployment_role = "${local.name_prefix}-trusted-deployment"

    subnets = data.aws_subnet_ids.subnets.ids
}
