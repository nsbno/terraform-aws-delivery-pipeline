/*
 * == Artifact Storage
 *
 * Any artifacts being deployed will be stored here.
 * This also triggers the pipelines.
 */
resource "aws_s3_bucket" "artifacts" {
    bucket = "${var.account_id}-${var.name_prefix}-delivery-pipeline-artifacts"
}

data "archive_file" "artifact_trigger" {
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
