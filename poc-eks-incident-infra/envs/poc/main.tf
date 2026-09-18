terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      ManagedBy   = "terraform"
      Environment = "poc"
    }
  }
}

# 도쿄 리전 — DevOps Agent EventBridge 규칙용
provider "aws" {
  alias  = "tokyo"
  region = "ap-northeast-1"

  default_tags {
    tags = {
      Project     = var.project
      ManagedBy   = "terraform"
      Environment = "poc"
    }
  }
}

module "network" {
  source  = "../../modules/network"
  project = var.project
  region  = var.aws_region
}

module "eks" {
  source = "../../modules/eks"

  project         = var.project
  cluster_version = var.cluster_version
  vpc_id          = module.network.vpc_id
  worker_subnet_ids = module.network.worker_subnet_ids
  node_desired_size  = var.node_desired_size
  node_min_size      = var.node_min_size
  node_max_size      = var.node_max_size
  node_instance_type = var.node_instance_type
  devops_agent_role_arn = var.devops_agent_role_arn
}

module "operator_iam" {
  source = "../../modules/operator-iam"

  project          = var.project
  cluster_name     = module.eks.cluster_name
  artifact_bucket_arn = module.storage.artifact_bucket_arn
  log_group_arn    = module.storage.log_group_arn
}

module "storage" {
  source = "../../modules/storage"

  project                       = var.project
  artifact_retention_days       = var.artifact_retention_days
  log_retention_days            = var.log_retention_days
  artifact_bucket_force_destroy = var.artifact_bucket_force_destroy
  devops_agent_role_name        = var.devops_agent_role_name
}

module "registry" {
  source  = "../../modules/registry"
  project = var.project
}

module "crew_host" {
  source = "../../modules/crew-host"

  project          = var.project
  vpc_id           = module.network.vpc_id
  subnet_id        = module.network.private_subnet_ids[0]
  ami_id           = var.crew_ami_id
  instance_type    = var.crew_instance_type
  cluster_name     = module.eks.cluster_name
  cluster_security_group_id = module.eks.cluster_security_group_id
  artifact_bucket_arn = module.storage.artifact_bucket_arn
  log_group_arn    = module.storage.log_group_arn
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  project      = var.project
  github_owner = var.github_owner
  github_repos = var.github_repos
}

# alt_path 모듈은 Phase 6에서 apply
# module "alt_path" { ... }

# ── Phase 5-2: H5 Bridge (DevOps Agent → Kiro Crew) ──────────────────────────
module "h5_bridge" {
  source = "../../modules/h5-bridge"

  providers = {
    aws       = aws
    aws.tokyo = aws.tokyo
  }

  project                = var.project
  agent_space_id         = var.agent_space_id
  crew_instance_id       = var.crew_instance_id
  slack_channel_id       = var.slack_channel_id
  crew_operator_role_arn = module.crew_host.operator_role_arn
}
