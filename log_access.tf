data "aws_iam_policy_document" "allow_central_account_assume_to_access_logs" {
  statement {
    principals {
      type        = "AWS"
      identifiers = [var.central_account]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "cross_account_logs_access" {
  name               = "logs-access"
  description        = "Role to access CloudWatch logs from Central account"
  assume_role_policy = data.aws_iam_policy_document.allow_central_account_assume_to_access_logs.json
}


data "aws_iam_policy_document" "cloudwatch_logs_policy" {
  name        = "CrossAccountCloudWatchLogsPolicy"
  description = "Policy to access deployment CloudWatch logs"
  statement {
    effect  = "Allow"
    actions = [
      "logs:GetLogEvents",
    ]
    resources = [
      "${aws_cloudwatch_log_group.ecs.arn}:*"
    ]
  }
}

resource "aws_iam_role_policy" "attach_cloudwatch_logs_policy" {
  role   = aws_iam_role.cross_account_logs_access.id
  policy = data.aws_iam_policy_document.cloudwatch_logs_policy.json
}
