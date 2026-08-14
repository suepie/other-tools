terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70, < 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # 設定値は bootstrap の出力を backend.hcl に書き、
  #   terraform init -backend-config=backend.hcl
  # で渡します（アカウントごとにバケット名が変わるためハードコードしない）
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "forge"
    }
  }
}
