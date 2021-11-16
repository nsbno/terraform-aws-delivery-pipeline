output "deployment_role" {
    value = aws_iam_role.deployment.arn
}

output "set_version_role" {
    value = aws_iam_role.set_version.arn
}
