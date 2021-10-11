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
    deployment_accounts = {
        # Infrademo accounts
        service = 689783162268
        test = 061938725231
        stage = 455398910694
        prod = 184682413771
    }
    deployment_role = "${local.name_prefix}-trusted-deployment"

    account_id = local.service_account_id
    subnets = data.aws_subnet_ids.subnets.ids
}

/*
 *  == Allow the pipeline to deploy our resources
 *
 *  This role allows us to deploy resources from the service account.
 *  It is required in all deployment accounts for the module to work.
 */
resource "aws_iam_role" "deployment" {
    name               = "${local.name_prefix}-trusted-deployment"
    assume_role_policy = data.aws_iam_policy_document.trusted_account_deployment_assume.json
}

data "aws_iam_policy_document" "trusted_account_deployment_assume" {
    statement {
        actions = ["sts:AssumeRole"]
        effect  = "Allow"
        principals {
            type        = "AWS"
            identifiers = ["arn:aws:iam::${local.service_account_id}:role/${local.name_prefix}-delivery-pipeline-trigger"]
        }
    }
}

resource "aws_iam_role_policy_attachment" "admin_to_deployment" {
    policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
    role       = aws_iam_role.deployment.id
}
