output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "artifact_bucket_name" {
  value = module.storage.artifact_bucket_name
}

output "log_group_name" {
  value = module.storage.log_group_name
}

output "operator_ecr_url" {
  value = module.registry.operator_ecr_url
}

output "app_ecr_url" {
  value = module.registry.app_ecr_url
}

output "crew_instance_id" {
  value = module.crew_host.instance_id
}

output "operator_role_arn" {
  value = module.operator_iam.role_arn
}

output "crew_reader_role_arn" {
  value = module.crew_host.reader_role_arn
}

output "crew_operator_role_arn" {
  value = module.crew_host.operator_role_arn
}
