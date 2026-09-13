output "cluster_name"     { value = aws_eks_cluster.main.name }
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }
output "cluster_ca"       { value = aws_eks_cluster.main.certificate_authority[0].data }
output "node_role_arn"    { value = aws_iam_role.node.arn }
output "cluster_role_arn" { value = aws_iam_role.cluster.arn }
