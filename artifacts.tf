/*
 * == Artifact Storage
 *
 * Any artifacts being deployed will be stored here.
 * This also triggers the pipelines.
 */
resource "aws_s3_bucket" "artifacts" {
    bucket = "${var.account_id}-${var.name_prefix}-delivery-pipeline-artifacts"
}

module "pipeline_orchistrator_artifact" {
    source = "./modules/build_artifact"

    input_path = "${path.module}/lambdas/pipeline_orchestrator"
    output_path = "${path.module}/lambdas/pipeline_orchestrator.zip"
}

resource "aws_lambda_function" "pipeline_orchestrator" {
    function_name = "${var.name_prefix}-delivery-pipeline-orchestrator"
    role = aws_iam_role.lambda_ecs_trigger.arn
    timeout = 600
    memory_size = 512

    runtime = "python3.9"
    handler = "pipeline_orchestrator.handler"

    filename = module.pipeline_orchistrator_artifact.artifact.output_path
    source_code_hash = module.pipeline_orchistrator_artifact.artifact.output_base64sha256

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
            STEP_FUNCTION_ROLE_ARN = aws_iam_role.sfn.arn

            # TODO: These are mostly hard coded based on the previous setup.
            SET_VERSION_LAMBDA_ARN = module.set_version.function_name
            SET_VERSION_ROLE = "${var.name_prefix}-trusted-set-version"
            SET_VERSION_SSM_PREFIX = "${var.name_prefix}/versions"
            SET_VERSION_ARTIFACT_BUCKET = aws_s3_bucket.artifacts.arn
        }
    }
}

resource "aws_cloudwatch_log_group" "lambda" {
    name = "/aws/lambda/${aws_lambda_function.pipeline_orchestrator.function_name}"
}

resource "aws_iam_role" "lambda_ecs_trigger" {
    name = "${var.name_prefix}-delivery-pipeline-orchestrator"
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

resource "aws_iam_role_policy" "lambda_allow_step_functions" {
    role = aws_iam_role.lambda_ecs_trigger.id
    policy = data.aws_iam_policy_document.lambda_allow_step_functions.json
}

data "aws_iam_policy_document" "lambda_allow_step_functions" {
    statement {
        effect = "Allow"
        actions = ["states:*"]
        # TODO: Scope down to only allow step functions created by this module.
        resources = ["*"]
    }
}

resource "aws_iam_role_policy" "lambda_allow_pass_role_to_step_functions" {
    role   = aws_iam_role.lambda_ecs_trigger.id
    policy = data.aws_iam_policy_document.lambda_allow_pass_role_to_step_functions.json
}

data "aws_iam_policy_document" "lambda_allow_pass_role_to_step_functions" {
    statement {
        effect = "Allow"
        actions = ["iam:PassRole"]
        resources = [aws_iam_role.sfn.arn]
    }
}

resource "aws_iam_role_policy" "lambda_allow_s3" {
    role = aws_iam_role.lambda_ecs_trigger.id
    policy = data.aws_iam_policy_document.lambda_allow_s3.json
}

data "aws_iam_policy_document" "lambda_allow_s3" {
    statement {
        effect = "Allow"
        actions = [
            "s3:*"
        ]
        resources = [
            aws_s3_bucket.artifacts.arn,
            "${aws_s3_bucket.artifacts.arn}/*"
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

