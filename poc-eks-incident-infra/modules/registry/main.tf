# Operator 이미지용 ECR
resource "aws_ecr_repository" "operator" {
  name                 = "${var.project}-operator"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
}

# 테스트 워크로드(app) 이미지용 ECR
resource "aws_ecr_repository" "app" {
  name                 = "${var.project}-app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
}

# 라이프사이클: 최신 30개 보관
resource "aws_ecr_lifecycle_policy" "operator" {
  repository = aws_ecr_repository.operator.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "최신 30개 이미지 보관"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "최신 30개 이미지 보관"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}
