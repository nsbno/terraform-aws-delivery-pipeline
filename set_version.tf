/*
 * = Setting versions for later deployment stages
 *
 * This makes sure that later steps in the pipeline has the correct versions
 * when trying to deploy.
 *
 * This updates SSM parameters to reference the latest version of the
 * applications.
 *
 * TODO: This should probably be architected differently to better allow for
 *       customization. Right now though, the focus is only on being able to
 *       duplicate previous functionality.
 */

module "set_version" {
    source      = "github.com/nsbno/terraform-aws-pipeline-set-version?ref=0.2.0"
    name_prefix = var.name_prefix
}

resource "aws_iam_role_policy" "set_version_assume_trusted_roles" {
    role   = module.set_version.lambda_exec_role_id
    policy = data.aws_iam_policy_document.set_version_assume_trusted_roles.json
}

data "aws_iam_policy_document" "set_version_assume_trusted_roles" {
    statement {
        effect    = "Allow"
        actions   = ["sts:AssumeRole"]
        resources = formatlist(
            "arn:aws:iam::%s:role/${var.name_prefix}-trusted-set-version",
            values(var.deployment_accounts)
        )
    }
}
