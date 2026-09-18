output "sns_topic_arn" {
  description = "H5 Bridge SNS 토픽 ARN"
  value       = aws_sns_topic.h5_bridge.arn
}

output "notifier_function_name" {
  description = "H5 Notifier Lambda 함수 이름"
  value       = aws_lambda_function.h5_notifier.function_name
}

output "eventbridge_rule_name" {
  description = "도쿄 EventBridge 규칙 이름"
  value       = aws_cloudwatch_event_rule.investigation_completed.name
}
