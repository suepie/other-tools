terraform {
  # S3 ネイティブロック（use_lockfile）を使うため 1.11 以上
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70, < 7.0"
    }
    # ecs/backend.hcl を自動生成するために使う
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  region = var.region

  # 環境変数 AWS_PROFILE に依存しないよう、tfvars からも指定できるようにする
  profile = var.aws_profile != "" ? var.aws_profile : null

  # 別アカウントの認証情報で実行された場合、リソースを触る前に停止する
  allowed_account_ids = length(var.allowed_account_ids) > 0 ? var.allowed_account_ids : null

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}
