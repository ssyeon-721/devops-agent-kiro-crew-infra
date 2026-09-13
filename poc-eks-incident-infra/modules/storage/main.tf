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
