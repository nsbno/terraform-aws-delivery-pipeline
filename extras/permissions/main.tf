data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

resource "vy_environment_account" "this" {
  owner = var.service_account_id
}

resource "aws_iam_role" "deployment" {
    name               = "${var.name_prefix}-trusted-deployment"
    assume_role_policy = data.aws_iam_policy_document.trusted_account_deployment_assume.json
}

data "aws_iam_policy_document" "trusted_account_deployment_assume" {
    statement {
        actions = ["sts:AssumeRole"]
        effect  = "Allow"
        principals {
            type        = "AWS"
            identifiers = ["arn:aws:iam::${var.service_account_id}:root"]
        }
        condition {
            test = "ArnEquals"
            variable = "aws:PrincipalArn"
            values = ["arn:aws:iam::${var.service_account_id}:role/${var.name_prefix}-deployment-task"]
        }
    }
}

resource "aws_iam_role_policy_attachment" "admin_to_deployment" {
    policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
    role       = aws_iam_role.deployment.id
}

resource "aws_iam_role" "set_version" {
    name               = "${var.name_prefix}-trusted-set-version"
    assume_role_policy = data.aws_iam_policy_document.trusted_account_assume.json
}

data "aws_iam_policy_document" "trusted_account_assume" {
    statement {
        actions = ["sts:AssumeRole"]
        effect  = "Allow"
        principals {
            type        = "AWS"
            identifiers = formatlist("arn:aws:iam::%s:root", var.service_account_id)
        }
    }
}

resource "aws_iam_role_policy" "ssm_to_set_version" {
    policy = data.aws_iam_policy_document.ssm_for_set_version.json
    role   = aws_iam_role.set_version.id
}

data "aws_iam_policy_document" "ssm_for_set_version" {
    statement {
        effect    = "Allow"
        actions   = ["ssm:PutParameter"]
        resources = [
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${var.name_prefix}/*",
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/artifacts/*",
        ]
    }
}

