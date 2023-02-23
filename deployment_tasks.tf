/*
 * == Cluster
 *
 * This is where the terraform container will be running.
 */
resource "aws_ecs_cluster" "cluster" {
    name = "${var.name_prefix}-delivery-pipeline"
}

resource "aws_cloudwatch_log_group" "ecs" {
    name = "/aws/ecs/${var.name_prefix}-delivery-pipeline"
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

resource "aws_iam_role_policy" "ecs_allow_step_function_invoke" {
    role = aws_iam_role.deployment_task.id
    policy = data.aws_iam_policy_document.ecs_allow_step_function_invoke.json
}

data "aws_iam_policy_document" "ecs_allow_step_function_invoke" {
    statement {
        effect = "Allow"
        actions = [
            "states:SendTaskSuccess",
            "states:SendTaskFailure",
        ]
        resources = [
            "*"
        ]
    }
}

resource "aws_iam_role_policy" "allow_artifact_bucket_access" {
    role   = aws_iam_role.deployment_task.id
    policy = data.aws_iam_policy_document.allow_artifact_bucket_access.json
}

data "aws_iam_policy_document" "allow_artifact_bucket_access" {
    statement {
        effect    = "Allow"
        actions   = ["s3:Get*", "s3:List*"]
        resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
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
            values(var.deployment_accounts)
        )
    }
}

# Security Group for the task
resource "aws_security_group" "deployment_task" {
  name  = "deployment_task"
  description = "Rules for deployment tasks"

  vpc_id = var.vpc_id
}

resource "aws_security_group_rule" "allow_all_outbound" {
  type              = "egress"
  security_group_id = aws_security_group.deployment_task.id
  protocol          = "all"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
}
