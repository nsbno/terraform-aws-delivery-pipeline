/*
 * == Trigger for terraform ECS Container
 *
 * This lambda will be used to create a single use ECS container.
 * The actual lambda is only allowed to interface with ECS and can only
 * create a terraform image. Users specify the version of terraform,
 * and which account to deploy to.
 *
 * There is a special case for production, where a check has to be passed before
 * being allowed to deploy.
 */
data "archive_file" "lambda_funtion" {
    type = "zip"
    source_dir = "${path.module}/"
    output_path = "${path.module}/ecs_task_creator.zip"
}

resource "aws_lambda_function" "ecs_trigger" {
    function_name = "${var.name_prefix}-delivery-pipeline-trigger"
    role = aws_iam_role.lambda_ecs_trigger.arn

    runtime = "python3.9"
    handler = "ecs_task_creator.handler"

    filename = data.archive_file.lambda_funtion.output_path
    source_code_hash = data.archive_file.lambda_funtion.output_base64sha256

    environment {
        variables = {
            ECS_CLUSTER = aws_ecs_cluster.cluster.arn
            DOCKER_IMAGE = var.docker_image
            EXECUTION_ROLE_ARN = aws_iam_role.execution_role.arn
            TASK_ROLE_ARN = aws_iam_role.deployment_task.arn
            TASK_FAMILY = "delivery-pipeline"  # TODO
            SUBNETS = jsonencode(var.subnets)
            LOG_GROUP = aws_cloudwatch_log_group.ecs.name
            ARTIFACT_BUCKET = aws_s3_bucket.artifacts.bucket
            DEPLOY_ROLE = var.deployment_role
            DEPLOY_ACCOUNTS = jsonencode(var.deployment_accounts)
        }
    }
}

resource "aws_cloudwatch_log_group" "lambda" {
    name = "/aws/lambda/${aws_lambda_function.ecs_trigger.function_name}"
}

resource "aws_iam_role" "lambda_ecs_trigger" {
    name = "${var.name_prefix}-delivery-pipeline-trigger"
    assume_role_policy = data.aws_iam_policy_document.lambda_ecs_trigger_assume.json
}

data "aws_iam_policy_document" "lambda_ecs_trigger_assume" {
    statement {
        effect = "Allow"
        actions = ["sts:AssumeRole"]
        principals {
            type = "Service"
            identifiers = ["lambda.amazonaws.com"]
        }
    }
}

resource "aws_iam_role_policy" "lambda_allow_logging" {
    role = aws_iam_role.lambda_ecs_trigger.id
    policy = data.aws_iam_policy_document.lambda_allow_logging.json
}

data "aws_iam_policy_document" "lambda_allow_logging" {
    statement {
        effect = "Allow"
        actions = [
            "logs:CreateLogStream",
            "logs:PutLogEvents"
        ]
        resources = [
            "${aws_cloudwatch_log_group.lambda.arn}:*"
        ]
    }
}

resource "aws_iam_role_policy" "lambda_allow_ecs" {
    role = aws_iam_role.lambda_ecs_trigger.id
    policy = data.aws_iam_policy_document.lambda_allow_ecs.json
}

data "aws_iam_policy_document" "lambda_allow_ecs" {
    statement {
        effect = "Allow"
        actions = [
            "ecs:DeregisterTaskDefinition",
            "ecs:RegisterTaskDefinition",
        ]
        resources = ["*"]
    }
    statement {
        effect    = "Allow"
        actions   = ["iam:PassRole"]
        resources = [
            aws_iam_role.deployment_task.arn,
            aws_iam_role.execution_role.arn
        ]
    }
    statement {
        effect    = "Allow"
        actions   = ["ecs:RunTask"]
        resources = ["*"]

        condition {
            test = "ArnEquals"
            variable = "ecs:cluster"
            values = [aws_ecs_cluster.cluster.arn]
        }
    }
}

