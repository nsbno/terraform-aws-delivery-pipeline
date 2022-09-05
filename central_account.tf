/*
 * = Components needed for the central account
 *
 * These components are used and accessed by the central deployment account.
 */

/*
 * == Deployment Account Permissions
 *
 *lambda_ecs_trigger Allow the deployment account to make changes to this account,
 * and read the pipelines.
 */

// This allows the deployment account to see incoming triggers and pipeline events
data "aws_iam_policy_document" "allow_subscription" {
  statement {
    principals {
      type        = "AWS"
      identifiers = var.central_accounts
    }

    resources = ["*"]
    actions   = ["SNS:Subscribe"]
  }
}

data "aws_iam_policy_document" "allow_central_account_assume" {
  statement {
    principals {
      type        = "AWS"
      identifiers = var.central_accounts
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "central_account" {
  name               = "deployment-access"
  description        = "Access for the central deployment account"
  assume_role_policy = data.aws_iam_policy_document.allow_central_account_assume.json
}

resource "aws_iam_role_policy" "central_account_allow_pass_role_to_step_functions" {
  role   = aws_iam_role.central_account.id
  policy = data.aws_iam_policy_document.central_account_allow_pass_role_to_step_functions.json
}

data "aws_iam_policy_document" "central_account_allow_pass_role_to_step_functions" {
  statement {
    effect = "Allow"
    actions = ["iam:PassRole"]
    resources = [aws_iam_role.sfn.arn]
  }
}

resource "aws_iam_role_policy" "central_account_allow_ecs" {
  role = aws_iam_role.central_account.id
  policy = data.aws_iam_policy_document.central_account_allow_ecs.json
}

data "aws_iam_policy_document" "central_account_allow_ecs" {
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

// The deployment account is responsible for managing everything around SFN.
data "aws_iam_policy_document" "allow_sfn" {
  statement {
    resources = ["*"]
    actions   = ["states:*"]
  }
}

resource "aws_iam_role_policy" "allow_sfn" {
  role = aws_iam_role.central_account.id

  name   = "allow-sfn-access"
  policy = data.aws_iam_policy_document.allow_sfn.json
}

// The deployment account has to be able to read all artifacts
data "aws_iam_policy_document" "allow_read_artifacts" {
  statement {
    resources = ["*"]
    actions   = [
      "s3:List*",
      "s3:Get*",
      "s3:Describe*",
      "ecr:List*",
      "ecr:Get*",
      "ecr:Describe*",
    ]
  }
}

resource "aws_iam_role_policy" "allow_read_artifacts" {
  role = aws_iam_role.central_account.id

  name   = "allow-read-artifacts"
  policy = data.aws_iam_policy_document.allow_read_artifacts.json
}

/*
 * == Incoming Triggers
 *
 * Triggers for starting the pipeline.
 */
resource "aws_sns_topic" "incoming_triggers" {
  name = "deployment-incoming-triggers.fifo"

  fifo_topic                  = true
  content_based_deduplication = true
}

resource "aws_sns_topic_policy" "incoming_triggers" {
  arn    = aws_sns_topic.incoming_triggers.arn
  policy = data.aws_iam_policy_document.allow_subscription.json
}


/*
 * == Outgoing Messages
 *
 * A way for the deployment agents to figure out what has changed.
 */
resource "aws_sns_topic" "outgoing_messages" {
  name = "deployment-outgoing-messages"
}

resource "aws_sns_topic_policy" "outgoing_messages" {
  arn    = aws_sns_topic.outgoing_messages.arn
  policy = data.aws_iam_policy_document.allow_subscription.json
}

resource "aws_cloudwatch_event_rule" "sfn_status" {
  description   = "Triggers when a State Machine changes status"
  event_pattern = <<-EOF
    {
      "source": [
        "aws.states"
      ],
      "detail-type": [
        "Step Functions Execution Status Change"
      ],
      "detail": {
        "status": ["RUNNING", "FAILED", "SUCCEEDED", "TIMED_OUT", "ABORTED"],
        "stateMachineArn": [
          {
            "prefix": ""
          }
        ]
      }
    }
  EOF
}

resource "aws_cloudwatch_event_target" "realtime" {
  arn  = aws_sns_topic.outgoing_messages.arn
  rule = aws_cloudwatch_event_rule.sfn_status.name
}

/*
 * == Account Information
 *
 * This is info about the account that will be used by the pipeline.
 */
locals {
  ssm_base_path = "deployment-pipeline"

  account_information = {
    aws_region      = data.aws_region.current.name
    artifact_bucket = aws_s3_bucket.artifacts.bucket

    # The role that the pipeline will assume into each account
    deploy_role = var.deployment_role
    # The accounts to deploy to
    deployment_accounts = jsonencode(var.deployment_accounts)

    # Info about where we're running the task
    execution_role_arn = aws_iam_role.execution_role.arn
    task_role_arn = aws_iam_role.deployment_task.arn
    ecs_cluster = aws_ecs_cluster.cluster.arn
    task_family = "delivery-pipeline"  # TODO: Don't hardcode
    subnets = jsonencode(var.subnets)
    security_groups = jsonencode([aws_security_group.deployment_task.id])
    log_group = aws_cloudwatch_log_group.ecs.name

    step_function_role_arn = aws_iam_role.sfn.arn

    # TODO: These are mostly hard coded based on the previous setup.
    set_version_lambda_arn = module.set_version.function_name
    set_version_role = "${var.name_prefix}-trusted-set-version"
    set_version_ssm_prefix = "artifacts"
    set_version_artifact_bucket = aws_s3_bucket.artifacts.bucket
  }
}

resource "aws_ssm_parameter" "account_information" {
  for_each = local.account_information

  name  = "/${local.ssm_base_path}/${each.key}"
  type  = "String"
  value = each.value
}

data "aws_iam_policy_document" "allow_read_account_information" {
  statement {
    resources = [
      "arn:aws:ssm:eu-west-1:${data.aws_caller_identity.current.account_id}:parameter/${local.ssm_base_path}",
      "arn:aws:ssm:eu-west-1:${data.aws_caller_identity.current.account_id}:parameter/${local.ssm_base_path}/*",
    ]
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
  }
}

resource "aws_iam_role_policy" "allow_read_account_information" {
  role = aws_iam_role.central_account.id

  name   = "allow-read-account-information"
  policy = data.aws_iam_policy_document.allow_read_account_information.json
}