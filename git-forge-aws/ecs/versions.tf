terraform {
  required_version = ">= 1.11"

  required_providers {
    # ECS Managed Instances（managed_instances_provider）は 6.15 以降で対応
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.15, < 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # terraform init -backend-config=backend.hcl で bootstrap の出力を渡します
  backend "s3" {}
}

provider "aws" {
  region = var.region

  # 別アカウントの認証情報で実行された場合、リソースを触る前に停止する
  allowed_account_ids = length(var.allowed_account_ids) > 0 ? var.allowed_account_ids : null

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "forge-ecs"
    }
  }
}

# CloudFront スコープの WAF は us-east-1 にしか作れないため、別プロバイダが必要
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  allowed_account_ids = length(var.allowed_account_ids) > 0 ? var.allowed_account_ids : null

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "forge-ecs"
    }
  }
}
