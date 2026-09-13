# poc-eks-incident-infra

EKS 인시던트 대응 자동화 검증 PoC — 인프라 (Terraform)

## 사전 준비

### 1. State 버킷 수동 생성

```bash
aws s3api create-bucket \
  --bucket poc-eks-incident-tfstate \
  --region ap-northeast-2 \
  --create-bucket-configuration LocationConstraint=ap-northeast-2

aws s3api put-bucket-versioning \
  --bucket poc-eks-incident-tfstate \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket poc-eks-incident-tfstate \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

### 2. GitHub OIDC 신뢰 역할 생성

IAM → Identity providers → `token.actions.githubusercontent.com` 등록 후,
`github-actions-terraform` 역할 생성. 신뢰 정책 예시:

```json
{
  "Condition": {
    "StringLike": {
      "token.actions.githubusercontent.com:sub": "repo:<ORG>/poc-eks-incident-infra:*"
    }
  }
}
```

### 3. AL2023 AMI ID 확인 후 tfvars 수정

```bash
aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --region ap-northeast-2 --query Parameter.Value --output text
```

`terraform.tfvars`의 `crew_ami_id`를 위 출력값으로 교체.

## Apply 순서

```bash
cd envs/poc
terraform init

# 순서 중요 — 의존성 때문에
terraform apply -target=module.network
terraform apply -target=module.eks
terraform apply -target=module.operator_iam -target=module.storage -target=module.registry -target=module.crew_host
```

> `alt_path` 모듈은 Phase 6에서 주석 해제 후 apply.

## 비용 절감

```bash
# 야간 노드그룹 스케일다운
terraform apply -var="node_desired_size=0"

# 재개
terraform apply -var="node_desired_size=2"
```

## 모듈 구성

| 모듈 | 리소스 |
|------|--------|
| network | VPC, 서브넷 (워커 /28), NAT, 라우팅 |
| eks | EKS 1.31+, 노드그룹, Pod Identity |
| operator_iam | Operator IAM Policy/Role, Pod Identity Association |
| storage | 인시던트 S3 버킷, CloudWatch 로그그룹 |
| registry | ECR (operator, app) |
| crew_host | Crew EC2, IAM 역할 2개 (reader/operator) |
| alt_path | CloudWatch 알람, SNS, Lambda (Phase 6) |
