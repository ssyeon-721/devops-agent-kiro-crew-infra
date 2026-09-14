variable "aws_region" {
  default = "ap-northeast-2"
}

variable "project" {
  default = "poc-eks-incident"
}

# EKS
variable "cluster_version" {
  default = "1.31"
}

variable "node_desired_size" {
  description = "워커 노드 desired count. 비용 절감 시 0으로"
  default     = 2
}

variable "node_min_size" {
  default = 0
}

variable "node_max_size" {
  default = 4
}

variable "node_instance_type" {
  default = "t3.large"
}

# Storage
variable "artifact_bucket_force_destroy" {
  description = "destroy 시 아티팩트 버킷 강제 삭제 여부"
  default     = false
}

variable "artifact_retention_days" {
  default = 30
}

variable "log_retention_days" {
  default = 14
}

# Crew EC2
variable "crew_instance_type" {
  default = "t3a.medium"
}

variable "crew_ami_id" {
  description = "AL2023 AMI ID (ap-northeast-2). 최신값은 콘솔에서 확인"
  # aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --region ap-northeast-2
  default = ""
}

# GitHub OIDC
variable "github_owner" {
  description = "GitHub 사용자 또는 조직명"
  default     = "ssyeon-721"
}

variable "github_repos" {
  description = "OIDC AssumeRole 허용 레포 목록"
  type        = list(string)
  default     = ["devops-agent-kiro-crew-infra", "poc-eks-incident-app"]
}

# DevOps Agent Space 조사 역할 (콘솔 auto-create)
# Agent가 EKS/S3를 조사하려면 이 역할에 접근 권한을 부여해야 한다.
variable "devops_agent_role_arn" {
  description = "DevOps Agent 조사 역할 ARN (EKS access entry 대상)"
  type        = string
  default     = ""
}

variable "devops_agent_role_name" {
  description = "DevOps Agent 조사 역할 이름 (S3 인시던트 버킷 읽기 권한 대상)"
  type        = string
  default     = ""
}
