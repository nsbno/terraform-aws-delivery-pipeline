terraform {
    required_version = ">= 1.0.0"
}

/*
 * == Terraform Apply Runner Cluster
 *
 * This is where the terraform container will be running.
 */
resource "aws_ecs_cluster" "cluster" {
    name = "${var.name_prefix}-delivery-pipeline"
    tags = var.tags
}

resource "aws_cloudwatch_log_group" "ecs" {
    name = "/aws/ecs/${var.name_prefix}-delivery-pipeline/terraform"
}

# Execution Role to allow Fargate to run our tasks.
resource "aws_iam_role" "execution_role" {
    name               = "${var.name_prefix}-deployment-pipeline-ecs-execution"
    assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "ECSTaskExecution" {
    role       = aws_iam_role.execution_role.id
    policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "ecs_assume" {
    statement {
        effect  = "Allow"
        actions = ["sts:AssumeRole"]
        principals {
            identifiers = ["ecs-tasks.amazonaws.com"]
            type        = "Service"
        }
    }
}

# Our general access rules for our terraform container
resource "aws_iam_role" "deployment_task" {
    name               = "${var.name_prefix}-deployment-task"
    assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
    tags               = var.tags
}

resource "aws_iam_role_policy" "ecs_allow_logging" {
    role = aws_iam_role.deployment_task.id
    policy = data.aws_iam_policy_document.ecs_allow_logging.json
}

data "aws_iam_policy_document" "ecs_allow_logging" {
    statement {
        effect = "Allow"
        actions = [
            "logs:CreateLogStream",
            "logs:PutLogEvents"
        ]
        resources = [
            "${aws_cloudwatch_log_group.ecs.arn}:*"
        ]
    }
}

resource "aws_iam_role_policy" "allow_assume_deployment_role" {
    role   = aws_iam_role.deployment_task.id
    policy = data.aws_iam_policy_document.allow_assume_deployment_role.json
}

data "aws_iam_policy_document" "allow_assume_deployment_role" {
    statement {
        effect    = "Allow"
        actions   = ["sts:AssumeRole"]
        resources = formatlist(
            "arn:aws:iam::%s:role/${var.deployment_role}",
            var.deployment_accounts
        )
    }
}


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
    source_file = "${path.module}/ecs_task_creator.py"
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
