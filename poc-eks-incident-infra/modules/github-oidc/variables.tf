variable "project" {}

variable "github_owner" {
  description = "GitHub 사용자 또는 조직명"
}

variable "github_repos" {
  description = "OIDC로 AssumeRole을 허용할 레포 목록 (owner/repo 형식)"
  type        = list(string)
}
