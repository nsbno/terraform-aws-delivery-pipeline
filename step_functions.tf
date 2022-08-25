/*
 * = Deployment Pipeline Scaffolding
 *
 * These are the resources needed to be able to deploy a functioning SFN pipeline.
 */
resource "aws_iam_role" "sfn" {
    name = "${var.name_prefix}-step-function-pipeline"
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

resource "aws_iam_role_policy" "sfn_lambda" {
    role = aws_iam_role.sfn.id
    policy = data.aws_iam_policy_document.sfn_lambda.json
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

data "aws_iam_policy_document" "sfn_lambda" {
    statement {
        effect = "Allow"
        actions = [
            "lambda:InvokeFunction",
        ]
        resources = [
            # TODO: This should be limited to the lambdas defined by this module,
            #       but the modules we import do not expose the ARNs.
            #       These external modules should probably be imported into this
            #       module when everything is working anyways.
            "*"
        ]
    }
}

data "aws_iam_policy_document" "sfn_sqs" {
  statement {
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
    ]
    resources = [
      "*"
    ]
  }
}

resource "aws_iam_role_policy" "sfn_sqs" {
  role = aws_iam_role.sfn.id
  policy = data.aws_iam_policy_document.sfn_sqs.json
}

module "metrics" {
  source = "github.com/nsbno/terraform-aws-pipeline-metrics?ref=0.2.0"

  name_prefix = var.name_prefix
}
