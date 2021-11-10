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

resource "aws_iam_role_policy" "sfn_do" {
    role = aws_iam_role.sfn.id
    policy = data.aws_iam_policy_document.sfn_do.json
}

data "aws_iam_policy_document" "sfn_do" {
    statement {
        effect = "Allow"
        actions = ["states:*"]
        # TODO: Scope down to only allow step functions created by this module.
        resources = ["*"]
    }
}

# Step Functions use
# Source:
# * https://stackoverflow.com/a/60623051/2824811
# * https://docs.aws.amazon.com/step-functions/latest/dg/stepfunctions-iam.html
resource "aws_iam_role_policy" "sfn_events" {
    role = aws_iam_role.sfn.id
    policy = data.aws_iam_policy_document.sfn_events.json
}

data "aws_iam_policy_document" "sfn_events" {
    statement {
        effect = "Allow"
        actions = [
            "events:PutTargets",
            "events:PutRule",
            "events:DescribeRule",
        ]
        resources = [
            "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:rule/StepFunctionsGetEventsFor*"
        ]
    }
}

resource "aws_iam_role_policy" "sfn_ecs" {
    role = aws_iam_role.sfn.id
    policy = data.aws_iam_policy_document.sfn_ecs.json
}

data "aws_iam_policy_document" "sfn_ecs" {
    statement {
        effect = "Allow"
        actions = [
            "ecs:RunTask",
            "ecs:StopTask",
            "ecs:DescribeTask",
        ]
        resources = ["*"]
    }

    statement {
        effect = "Allow"
        actions = ["iam:PassRole"]
        resources = [
            aws_iam_role.execution_role.arn,
            aws_iam_role.deployment_task.arn,
        ]
    }
}

resource "aws_iam_role_policy" "lambda_pass_role" {
    role = aws_iam_role.lambda_ecs_trigger.id
    policy = data.aws_iam_policy_document.lambda_allow_sfn_pass.json
}

data "aws_iam_policy_document" "lambda_allow_sfn_pass" {
    statement {
        effect = "Allow"
        actions = ["iam:PassRole"]
        resources = [aws_iam_role.sfn.arn]
    }
}
