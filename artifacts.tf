/*
 * == Artifact Storage
 *
 * Any artifacts being deployed will be stored here.
 * This also triggers the pipelines.
 */
resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.account_id}-${var.name_prefix}-delivery-pipeline-artifacts"
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "allow_account_access" {
  statement {
    principals {
      type        = "AWS"
      identifiers = concat(
        var.deployment_accounts.dev != null ? [var.deployment_accounts.dev] : [],
        [
          var.deployment_accounts.test,
          var.deployment_accounts.stage,
          var.deployment_accounts.prod,
        ])
    }

    actions = [
      "s3:ListBucket",
      "s3:GetObject*",
    ]

    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }
}

resource "aws_s3_bucket_policy" "allow_account_access" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.allow_account_access.json
}

