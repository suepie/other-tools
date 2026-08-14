variable "project" {
  description = "プロジェクト識別子。リソース名の接頭辞になります"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}$", var.project))
    error_message = "project は英小文字・数字・ハイフンで 2〜31 文字にしてください。"
  }
}

variable "region" {
  description = "リソースを作成するリージョン。ECS Managed Instances 対応リージョンである必要があります"
  type        = string
  default     = "ap-northeast-1"
}

# ---- アクセス制限 --------------------------------------------------------

variable "allowed_cidrs" {
  description = <<-EOT
    Forgejo に接続を許可する送信元 CIDR のリスト（固定 IP）。
    ここが唯一の入口です。
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0
    error_message = "allowed_cidrs は 1 件以上指定してください。"
  }

  validation {
    condition     = !contains(var.allowed_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 は指定できません。IP 制限が目的のスタックです。"
  }
}

# ---- DNS / TLS -----------------------------------------------------------

variable "domain_name" {
  description = "Forgejo の FQDN。例: git-projecta.example.com"
  type        = string
}

variable "route53_zone_id" {
  description = "domain_name を含む Route 53 ホストゾーン ID"
  type        = string
}

# ---- コンピュート --------------------------------------------------------

variable "instance_vcpu_min" {
  description = "Managed Instances が選ぶインスタンスの最小 vCPU"
  type        = number
  default     = 2
}

variable "instance_memory_mib_min" {
  description = "Managed Instances が選ぶインスタンスの最小メモリ (MiB)"
  type        = number
  default     = 4096
}

variable "instance_storage_gib" {
  description = "Managed Instances のインスタンスストレージ (GiB)。CI のビルド作業領域もここを使います"
  type        = number
  default     = 100
}

variable "cpu_manufacturers" {
  description = <<-EOT
    許可する CPU メーカー。Forgejo は arm64 対応なので Graviton を含められます。
    CI で x86 バイナリをビルドする必要があるなら ["intel", "amd"] に絞ってください。
  EOT
  type        = list(string)
  default     = ["amazon-web-services", "intel", "amd"]
}

# ---- コンテナイメージ ----------------------------------------------------

variable "forge_image" {
  description = "Forgejo のイメージ。★タグは公式で最新を確認して固定してください"
  type        = string
  default     = "codeberg.org/forgejo/forgejo:11"
}

variable "runner_image" {
  description = "Forgejo Actions ランナーのイメージ。★タグは公式で確認してください"
  type        = string
  default     = "code.forgejo.org/forgejo/runner:9"
}

variable "runner_labels" {
  description = "ランナーのラベル。ワークフローの runs-on に書く値"
  type        = string
  default     = "docker:docker://node:22-bookworm"
}

variable "enable_runner" {
  description = "Actions ランナーを動かすか"
  type        = bool
  default     = true
}

# ---- データベース --------------------------------------------------------

variable "db_instance_class" {
  description = "RDS のインスタンスクラス"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "RDS のストレージ (GiB)"
  type        = number
  default     = 20
}

variable "db_engine_version" {
  description = "PostgreSQL のメジャーバージョン"
  type        = string
  default     = "16"
}

variable "db_backup_retention_days" {
  description = "RDS 自動バックアップの保持日数"
  type        = number
  default     = 14
}

# ---- 管理者 --------------------------------------------------------------

variable "admin_username" {
  description = "初期管理者のユーザー名"
  type        = string
  default     = "forgeadmin"
}

variable "admin_email" {
  description = "初期管理者のメールアドレス"
  type        = string
}

# ---- その他 --------------------------------------------------------------

variable "vpc_cidr" {
  description = "VPC の CIDR"
  type        = string
  default     = "10.20.0.0/16"
}

variable "secret_recovery_window_days" {
  description = "Secrets Manager の削除猶予日数。0 は検証向け。本番は 7〜30 を推奨"
  type        = number
  default     = 0
}

variable "log_retention_days" {
  description = "CloudWatch Logs の保持日数"
  type        = number
  default     = 30
}
