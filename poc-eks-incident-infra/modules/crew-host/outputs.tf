output "instance_id"        { value = aws_instance.crew.id }
output "reader_role_arn"    { value = aws_iam_role.crew_reader.arn }
output "operator_role_arn"  { value = aws_iam_role.crew_operator.arn }
