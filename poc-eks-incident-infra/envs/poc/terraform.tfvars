aws_region         = "ap-northeast-2"
project            = "poc-eks-incident"
# 실제 클러스터는 1.34로 자동 업그레이드됨 — 드리프트 방지를 위해 코드도 정렬
cluster_version    = "1.34"
node_desired_size  = 2
node_instance_type = "t3.large"
# t3a.large(8GB) — Crew spawn 서브에이전트가 최소 4GB 요구, medium(4GB)로는 부족
crew_instance_type = "t3a.large"

# AL2023 AMI — apply 전에 최신값으로 교체
# aws ssm get-parameter \
#   --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
#   --region ap-northeast-2 --query Parameter.Value --output text
crew_ami_id = "ami-0fad23d064f9e8330"

artifact_bucket_force_destroy = false
artifact_retention_days       = 30
log_retention_days            = 14

# OIDC AssumeRole 허용 레포 (ECR 푸시용)
# operator 레포 추가: Phase 2에서 Operator 이미지를 CI로 빌드/푸시
github_repos = [
  "devops-agent-kiro-crew-infra",
  "poc-eks-incident-app",
  "poc-eks-incident-operator",
]

# DevOps Agent Space(poc-eks-incident-agent, 도쿄) 조사 역할 — 콘솔 auto-create
# Agent가 EKS(K8s API)와 S3 인시던트 아티팩트를 조사할 수 있도록 권한 부여
# 주의: Agent Space를 재생성하면 역할 접미사가 바뀌므로 값 갱신 필요
devops_agent_role_arn  = "arn:aws:iam::084828589246:role/service-role/DevOpsAgentRole-AgentSpace-6j8n9zaq"
devops_agent_role_name = "DevOpsAgentRole-AgentSpace-6j8n9zaq"

# H5 Bridge — Phase 5-2
# DevOps Agent Space ID (도쿄, poc-eks-incident-agent)
agent_space_id   = "0786d7f0-108f-48a6-8c42-b84c5d93cf3b"
# Crew EC2 인스턴스 ID
crew_instance_id = "i-03d7e0868fb975158"
# DevOps Agent 조사 결과 수신 Slack 채널
slack_channel_id = "C0C1EDPAEMR"
