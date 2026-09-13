terraform {
  backend "s3" {
    bucket       = "poc-eks-incident-tfstate"
    key          = "poc/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
