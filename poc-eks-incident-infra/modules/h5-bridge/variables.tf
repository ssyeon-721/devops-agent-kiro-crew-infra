variable "project" {
  description = "프로젝트 prefix"
  type        = string
}

variable "agent_space_id" {
  description = "도쿄 DevOps Agent Space ID (EventBridge 필터용)"
  type        = string
}

variable "crew_instance_id" {
  description = "Crew EC2 인스턴스 ID (SSM SendCommand 대상)"
  type        = string
}

variable "slack_secret_id" {
  description = "Slack 토큰이 저장된 Secrets Manager 시크릿 이름"
  type        = string
  default     = "kiro-crew/slack-tokens"
}

variable "slack_channel_id" {
  description = "DevOps Agent 조사 결과를 수신할 Slack 채널 ID"
  type        = string
}
