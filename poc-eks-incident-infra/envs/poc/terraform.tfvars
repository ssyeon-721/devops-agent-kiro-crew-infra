aws_region         = "ap-northeast-2"
project            = "poc-eks-incident"
cluster_version    = "1.31"
node_desired_size  = 2
node_instance_type = "t3.large"
crew_instance_type = "t3a.medium"

# AL2023 AMI — apply 전에 최신값으로 교체
# aws ssm get-parameter \
#   --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
#   --region ap-northeast-2 --query Parameter.Value --output text
crew_ami_id = "ami-0fad23d064f9e8330"

artifact_bucket_force_destroy = false
artifact_retention_days       = 30
log_retention_days            = 14
