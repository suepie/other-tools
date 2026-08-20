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

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "forge-ecs"
    }
  }
}
