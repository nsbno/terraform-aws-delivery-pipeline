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
  allowed_account_ids = [689783162268]
}

locals {
  name_prefix        = "deployer-example"
  service_account_id = 689783162268
}

# Get some existing subnets from our VPC
data "aws_subnet_ids" "subnets" {
  vpc_id = "vpc-088edf3000b91734f"

  tags = {
    Type = "Public"
  }
}


/*
 * == Create the deployment pipeline
 *
 * This is the boilerplate for creating the deployment pipeline.
 */
module "deployment_pipeline" {
  source = "../../../"

  name_prefix = local.name_prefix

  central_accounts    = ["1234567890"]
  account_id          = local.service_account_id
  deployment_accounts = {
    # Infrademo accounts
    service = 689783162268
    test    = 061938725231
    stage   = 455398910694
    prod    = 184682413771
  }

  deployment_role = module.deployment_pipeline_permissions.deployment_role

  vpc_id  = "vpc-088edf3000b91734f"
  subnets = data.aws_subnet_ids.subnets.ids
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


/*
 * == Allow the CI to trigger the pipeline
 *
 * This allows CircleCI to trigger a deployment and upload built containers
 * and zip files.
 */

resource "aws_kms_key" "ci-parameters" {
  description = "KMS key for encrypting parameters shared with CircleCI."
}

resource "aws_kms_alias" "key-alias" {
  name          = "alias/${local.name_prefix}-ci-parameters"
  target_key_id = aws_kms_key.ci-parameters.id
}

module "ci_machine_user" {
  source                = "github.com/nsbno/terraform-aws-circleci-repository-user?ref=d9fb611"
  name_prefix           = local.name_prefix
  allowed_s3_write_arns = [
    module.deployment_pipeline.artifact_bucket_arn
  ]
  allowed_s3_read_arns = []
  allowed_ecr_arns     = []
  ci_parameters_key    = aws_kms_alias.key-alias.id
}

# The CI must be able to trigger a deployment.
# This will be part of the CircleCI module in the future.
resource "aws_iam_user_policy" "machine_user_lambda" {
  user   = module.ci_machine_user.user_name
  policy = data.aws_iam_policy_document.machine_user_lambda.json
}

data "aws_iam_policy_document" "machine_user_lambda" {
  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [module.deployment_pipeline.in]
  }
}

