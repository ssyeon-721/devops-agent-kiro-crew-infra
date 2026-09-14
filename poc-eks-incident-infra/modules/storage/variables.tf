variable "project"                       {}
variable "artifact_retention_days"       { type = number }
variable "log_retention_days"            { type = number }
variable "artifact_bucket_force_destroy" { type = bool }

# DevOps Agent Space 조사 역할 이름(콘솔 auto-create). 인시던트 버킷 읽기 권한 부여 대상.
# 빈 문자열이면 정책을 만들지 않는다(선택적).
variable "devops_agent_role_name" {
  description = "DevOps Agent 조사 역할 이름 (S3 인시던트 버킷 읽기 권한 부여)"
  type        = string
  default     = ""
}
