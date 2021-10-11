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
    allowed_account_ids = [455398910694]
}

locals {
    name_prefix = "deployer-example"
    service_account_id = 689783162268
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
