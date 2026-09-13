output "artifact_bucket_name" { value = aws_s3_bucket.artifacts.id }
output "artifact_bucket_arn"  { value = aws_s3_bucket.artifacts.arn }
output "log_group_name"       { value = aws_cloudwatch_log_group.operator.name }
output "log_group_arn"        { value = aws_cloudwatch_log_group.operator.arn }
