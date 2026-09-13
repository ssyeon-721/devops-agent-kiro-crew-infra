data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── 보안그룹 ──────────────────────────────────────────────
resource "aws_security_group" "crew" {
  name        = "${var.project}-crew-sg"
  description = "Kiro Crew EC2 - no inbound, SSM access only"
  vpc_id      = var.vpc_id

  # 인바운드 0 (SSH 없음, SSM Session Manager로만 접속)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "all outbound"
  }

  tags = { Name = "${var.project}-crew-sg" }
}

# ── EC2 인스턴스 ──────────────────────────────────────────
resource "aws_instance" "crew" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.crew.id]
  iam_instance_profile   = aws_iam_instance_profile.crew.name

  # Crew 설치는 Phase 5에서 수동. user_data 최소화
  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y python3.12 python3.12-pip git
  EOF
  )

  metadata_options {
    http_tokens   = "required" # IMDSv2 강제
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  # Phase 1에서는 stopped 상태로 유지
  # aws ec2 stop-instances --instance-ids <id>

  tags = { Name = "${var.project}-crew-host" }
}

# ── IAM: 인스턴스 프로파일 ────────────────────────────────
resource "aws_iam_instance_profile" "crew" {
  name = "${var.project}-crew-instance-profile"
  role = aws_iam_role.crew_base.name
}

# 기본 인스턴스 역할 — SSM 접속 + reader/operator AssumeRole 권한
resource "aws_iam_role" "crew_base" {
  name = "${var.project}-crew-base-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "crew_ssm" {
  role       = aws_iam_role.crew_base.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "crew_assume_reader" {
  name = "assume-reader-operator"
  role = aws_iam_role.crew_base.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = [
        aws_iam_role.crew_reader.arn,
        aws_iam_role.crew_operator.arn,
      ]
    }]
  })
}

# ── Crew 읽기 전용 역할 ────────────────────────────────────
resource "aws_iam_role" "crew_reader" {
  name = "kirocrew-triage-reader"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.crew_base.arn }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "crew_reader_policy" {
  name = "triage-reader-policy"
  role = aws_iam_role.crew_reader.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EKSDescribe"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListNodegroups",
          "eks:DescribeNodegroup",
          "eks:ListAddons",
        ]
        Resource = "*"
      },
      {
        Sid    = "LogsRead"
        Effect = "Allow"
        Action = [
          "logs:FilterLogEvents",
          "logs:GetLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = [
          var.log_group_arn,
          "${var.log_group_arn}:*",
        ]
      },
      {
        Sid    = "S3ArtifactRead"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          var.artifact_bucket_arn,
          "${var.artifact_bucket_arn}/*",
        ]
      },
      {
        Sid    = "EC2Describe"
        Effect = "Allow"
        Action = ["ec2:Describe*"]
        Resource = "*"
      },
    ]
  })
}

# ── Crew 조치 역할 (승인 후 AssumeRole, 세션 15분) ─────────
resource "aws_iam_role" "crew_operator" {
  name = "kirocrew-triage-operator"
  # IAM 역할 max_session_duration 하한은 3600초(1시간).
  # 실제 15분 제한은 Crew가 AssumeRole 시 --duration-seconds 900으로 지정하여 달성한다.
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.crew_base.arn }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "crew_operator_policy" {
  name = "triage-operator-policy"
  role = aws_iam_role.crew_operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "K8sDeploymentControl"
        Effect = "Allow"
        # 실제 K8s 리소스 제어는 aws-auth / EKS access entry로 네임스페이스 한정
        # 이 정책은 EKS 클러스터 접근 자격을 위한 최소 권한
        Action = [
          "eks:DescribeCluster",
        ]
        Resource = "arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
      },
    ]
  })
}
