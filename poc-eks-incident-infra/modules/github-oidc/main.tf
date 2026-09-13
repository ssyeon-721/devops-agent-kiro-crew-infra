data "aws_caller_identity" "current" {}

# GitHub Actions OIDC Provider
# thumbprint는 현재 AWS가 자동 검증하므로 대표값 사용
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# GitHub Actions가 AssumeRole할 역할
resource "aws_iam_role" "github_actions" {
  name = "github-actions-terraform"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # 지정한 레포의 모든 브랜치/이벤트에서 AssumeRole 허용
          # 개인 계정 토큰은 sub에 owner ID/repo ID가 붙는다:
          #   repo:owner@<ownerId>/repo@<repoId>:ref:refs/heads/main
          # 이를 커버하기 위해 owner/repo 뒤에 와일드카드를 둔다.
          "token.actions.githubusercontent.com:sub" = flatten([
            for repo in var.github_repos : [
              "repo:${var.github_owner}/${repo}:*",
              "repo:${var.github_owner}*/${repo}*:*",
            ]
          ])
        }
      }
    }]
  })
}

# app CI용: ECR 푸시 권한
resource "aws_iam_role_policy" "ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = "arn:aws:ecr:*:${data.aws_caller_identity.current.account_id}:repository/${var.project}-*"
      },
    ]
  })
}
