output "artifact_bucket_arn" {
    value = aws_s3_bucket.artifacts.arn
}

output "cluster_arn" {
    value = aws_ecs_cluster.cluster.arn
}

output "ecs_log_group_arn" {
    value = aws_cloudwatch_log_group.ecs.arn
}

output "orchestrator_lambda_arn" {
    value = aws_lambda_function.pipeline_orchestrator.arn
}
