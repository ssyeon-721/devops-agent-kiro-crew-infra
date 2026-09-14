variable "project"             {}
variable "vpc_id"              {}
variable "subnet_id"           {}
variable "ami_id"              {}
variable "instance_type"       {}
variable "cluster_name"        {}
variable "cluster_security_group_id" {
  description = "EKS 클러스터 보안그룹 ID (Crew에서 API 443 인바운드 허용용)"
}
variable "artifact_bucket_arn" {}
variable "log_group_arn"       {}
