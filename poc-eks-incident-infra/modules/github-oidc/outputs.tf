output "role_arn"     { value = aws_iam_role.github_actions.arn }
output "provider_arn" { value = aws_iam_openid_connect_provider.github.arn }
