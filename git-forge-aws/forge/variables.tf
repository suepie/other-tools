variable "project" {
  description = "プロジェクト識別子。リソース名の接頭辞になります"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}$", var.project))
    error_message = "project は英小文字・数字・ハイフンで 2〜31 文字にしてください。"
  }
}

variable "region" {
  description = "リソースを作成するリージョン"
  type        = string
  default     = "ap-northeast-1"
}

# ---- アクセス制限 --------------------------------------------------------

variable "allowed_cidrs" {
  description = <<-EOT
    Forge に接続を許可する送信元 CIDR のリスト（固定 IP を想定）。
    ここが唯一の入口です。空にすると誰も繋がらなくなります。
    例: ["203.0.113.10/32", "198.51.100.0/24"]
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
  description = "Forge の FQDN。例: git-projecta.example.com"
  type        = string
}

variable "route53_zone_id" {
  description = "domain_name を含む Route 53 ホストゾーン ID（ACM の DNS 検証に使用）"
  type        = string
}

# ---- インスタンス --------------------------------------------------------

variable "instance_type" {
  description = "EC2 インスタンスタイプ。Forgejo/Gitea は arm64 対応なので Graviton が使えます"
  type        = string
  default     = "t4g.small"
}

variable "data_volume_size" {
  description = "リポジトリを置く EBS データボリュームのサイズ（GiB）"
  type        = number
  default     = 50
}

variable "data_volume_type" {
  description = "データボリュームのタイプ"
  type        = string
  default     = "gp3"
}

# ---- コンテナイメージ ----------------------------------------------------

variable "forge_image" {
  description = <<-EOT
    Forge のコンテナイメージ。既定は Forgejo。
    Gitea にする場合は "gitea/gitea:1.24" のように差し替えます
    （その場合 cloud-init 内の forgejo CLI 呼び出しを gitea CLI に読み替える必要があります）。
    ★タグは必ず公式で最新を確認して固定してください。
  EOT
  type        = string
  default     = "codeberg.org/forgejo/forgejo:11"
}

variable "runner_image" {
  description = "Actions ランナーのコンテナイメージ。★タグは公式で最新を確認してください"
  type        = string
  default     = "code.forgejo.org/forgejo/runner:9"
}

variable "runner_labels" {
  description = "ランナーのラベル。ワークフローの runs-on に書く値"
  type        = string
  default     = "docker:docker://node:22-bookworm,ubuntu-latest:docker://node:22-bookworm"
}

variable "enable_runner" {
  description = "Actions ランナーを同居させるか。false なら Forge のみ"
  type        = bool
  default     = true
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

variable "backup_time_utc" {
  description = "データボリュームのスナップショットを取る時刻（UTC, HH:MM）。既定は JST 03:00 相当"
  type        = string
  default     = "18:00"
}

variable "backup_retention_count" {
  description = "保持するスナップショット世代数"
  type        = number
  default     = 14
}

variable "secret_recovery_window_days" {
  description = <<-EOT
    Secrets Manager の削除猶予日数。
    0 は「destroy 後すぐ同名で作り直せる」検証向けの設定です。本番は 7〜30 を推奨。
  EOT
  type        = number
  default     = 0
}
