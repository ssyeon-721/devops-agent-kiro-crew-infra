variable "project"           {}
variable "cluster_version"   {}
variable "vpc_id"            {}
variable "worker_subnet_ids" { type = list(string) }
variable "node_desired_size" { type = number }
variable "node_min_size"     { type = number }
variable "node_max_size"     { type = number }
variable "node_instance_type" {}

# DevOps Agent(도쿄 Agent Space)가 콘솔에서 auto-create한 IAM 역할 ARN.
# 이 역할에 EKS 읽기 접근을 부여해야 Agent가 K8s API로 조사할 수 있다.
# 빈 문자열이면 access entry를 만들지 않는다(선택적).
variable "devops_agent_role_arn" {
  description = "DevOps Agent Space 조사 역할 ARN (EKS read access 부여 대상)"
  type        = string
  default     = ""
}
