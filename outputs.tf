output "trigger_role_arn" {
    value = aws_iam_role.lambda_ecs_trigger.arn
}

output "trigger_lambda_arn" {
    value = aws_lambda_function.ecs_trigger.arn
}
