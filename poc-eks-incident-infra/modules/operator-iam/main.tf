data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Operator IAM Policy
resource "aws_iam_policy" "operator" {
  name        = "devops-agent-operator-policy"
  description = "DevOps Agent Operator — 최소 권한"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMNodeCollection"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
        ]
        Resource = [
          "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript",
        ]
      },
      {
        Sid    = "S3ArtifactWrite"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = "${var.artifact_bucket_arn}/incidents/*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${var.log_group_arn}:*"
      },
    ]
  })
}

# Operator IAM Role (Pod Identity용)
resource "aws_iam_role" "operator" {
  name = "devops-agent-operator-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession",
      ]
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "operator" {
  role       = aws_iam_role.operator.name
  policy_arn = aws_iam_policy.operator.arn
}

# Pod Identity Association
# namespace/service_account는 배포 매니페스트(examples/)와 정확히 일치해야 함.
# 표준 예제의 네임스페이스는 devops-agent-operator-system 이다.
resource "aws_eks_pod_identity_association" "operator" {
  cluster_name    = var.cluster_name
  namespace       = "devops-agent-operator-system"
  service_account = "devops-agent-operator"
  role_arn        = aws_iam_role.operator.arn
}
