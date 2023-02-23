output "deployment_role_name" {
  value = aws_iam_role.deployment.name
}

output "deployment_role" {
    value = aws_iam_role.deployment.arn
}

output "set_version_role" {
    value = aws_iam_role.set_version.arn
}
