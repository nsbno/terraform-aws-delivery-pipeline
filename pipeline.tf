/*
 * = Deployment Pipeline Scaffolding
 *
 * These are the resources needed to be able to deploy a functioning SFN pipeline.
 */
resource "aws_iam_role" "sfn" {
    assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

data "aws_iam_policy_document" "sfn_assume" {
    statement {
        effect  = "Allow"
        actions = ["sts:AssumeRole"]
        principals {
            identifiers = ["states.amazonaws.com"]
            type        = "Service"
        }
    }
}

resource "aws_iam_role_policy" "lambda_to_sfn" {
    policy = data.aws_iam_policy_document.lambda_for_sfn.json
    role   = aws_iam_role.sfn.id
}

data "aws_iam_policy_document" "lambda_for_sfn" {
    statement {
        effect  = "Allow"
        actions = ["lambda:InvokeFunction"]
        resources = [
            "arn:aws:lambda:${local.current_region}:${local.current_account_id}:function:${module.set_version.function_name}",
            "arn:aws:lambda:${local.current_region}:${local.current_account_id}:function:${module.single_use_fargate_task.function_name}",
            "arn:aws:lambda:${local.current_region}:${local.current_account_id}:function:${module.error_catcher.function_name}"
        ]
    }
}
