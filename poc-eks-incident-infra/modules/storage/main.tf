# 인시던트 아티팩트 S3 버킷
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.project}-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.artifact_bucket_force_destroy

  tags = { Name = "${var.project}-artifacts" }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-incidents"
    status = "Enabled"

    filter { prefix = "incidents/" }

    expiration { days = var.artifact_retention_days }

    noncurrent_version_expiration { noncurrent_days = 7 }
  }
}

# CloudWatch 로그그룹
resource "aws_cloudwatch_log_group" "operator" {
  name              = "cw-log-group-devops-agent-operator"
  retention_in_days = var.log_retention_days
}

# DevOps Agent 조사 역할에 인시던트 아티팩트 읽기 권한 부여.
# Operator는 S3에 쓰고(PutObject), Agent는 조사 시 그 아티팩트를 읽어야(GetObject) 하는데
# Agent auto-create 역할엔 우리 버킷 접근 권한이 없어 조사에서 AccessDenied 발생 → 여기서 부여.
# devops_agent_role_name이 비어있으면 생성하지 않는다.
resource "aws_iam_role_policy" "agent_s3_read" {
  count = var.devops_agent_role_name != "" ? 1 : 0
  name  = "poc-eks-incident-agent-s3-read"
  role  = var.devops_agent_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadIncidentArtifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/incidents/*",
        ]
      },
    ]
  })
}
