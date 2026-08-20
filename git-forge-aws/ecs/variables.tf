variable "project" {
  description = "プロジェクト識別子。リソース名の接頭辞になります"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}$", var.project))
    error_message = "project は英小文字・数字・ハイフンで 2〜31 文字にしてください。"
  }
}

variable "component" {
  description = <<-EOT
    用途を表す識別子。リソース名が「project-component-...」になります。

    同じアカウントに別のスタックを置いたときに見分けが付くようにするためのものです。
    既定の "git" なら project-a-git-vpc のようになります。
  EOT
  type        = string
  default     = "git"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,15}$", var.component))
    error_message = "component は英小文字・数字・ハイフンで 1〜16 文字にしてください。"
  }

  # project との合計長（ALB 名の 32 文字上限）は alb.tf の precondition で検査します。
  # 変数バリデーションから他の変数を参照するのは Terraform 1.9 以降に限られるうえ、
  # 制約が効く場所の近くに置いたほうが分かりやすいためです。
}

variable "region" {
  description = "リソースを作成するリージョン。ECS Managed Instances 対応リージョンである必要があります"
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_profile" {
  description = <<-EOT
    使用する AWS プロファイル名（~/.aws/config の [profile xxx] の xxx）。

    指定すると環境変数 AWS_PROFILE に依存しなくなります。ターミナルを開き直して
    export が消え、"no valid credential sources found" になる事故を防げます。
    空にすると通常どおり環境変数や既定のプロファイルを見ます。
  EOT
  type        = string
  default     = ""
}

variable "allowed_account_ids" {
  description = <<-EOT
    このスタックを適用してよい AWS アカウント ID のリスト。

    複数アカウントを扱うときの誤適用防止です。ここに書いたアカウント以外の
    認証情報で実行すると、Terraform がリソースを触る前にエラーで止まります。
    AWS_PROFILE の切り替え忘れが事故にならなくなるので、指定を強く推奨します。

    例: ["111111111111"]
    空にするとチェックしません。
  EOT
  type        = list(string)
  default     = []
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

# ---- CloudFront ----------------------------------------------------------
#
# 独自ドメインは使いません。CloudFront の既定ドメイン（*.cloudfront.net）には
# 有効な TLS 証明書が最初から付いているため、ドメインを持たずに正規の HTTPS を張れます。

variable "origin_read_timeout" {
  description = <<-EOT
    CloudFront がオリジンからの応答を待つ秒数（1〜120。既定の 30 は Git には短い）。

    これは「合計時間」ではなく「無通信が続いた時間」です。データが流れ続けている限り
    タイムアウトしません。効いてくるのは push 後にサーバが pack を展開・フック実行・
    ref 更新する無通信区間で、大きな push だと 30 秒を超えます。
    120 を超える値が必要ならクォータ引き上げを申請してください。
  EOT
  type        = number
  default     = 120

  validation {
    condition     = var.origin_read_timeout >= 1 && var.origin_read_timeout <= 120
    error_message = "origin_read_timeout は 1〜120 秒です。これを超える場合はクォータ引き上げ申請が必要です。"
  }
}

variable "origin_keepalive_timeout" {
  description = "CloudFront がオリジンとの接続を維持する秒数（1〜300）"
  type        = number
  default     = 60

  validation {
    condition     = var.origin_keepalive_timeout >= 1 && var.origin_keepalive_timeout <= 300
    error_message = "origin_keepalive_timeout は 1〜300 秒です。"
  }
}

variable "cloudfront_price_class" {
  description = "CloudFront の価格クラス。日本国内利用なら PriceClass_200 で足ります"
  type        = string
  default     = "PriceClass_200"
}

variable "excluded_az_ids" {
  description = <<-EOT
    使用しない AZ の ID。
    CloudFront VPC オリジンは一部の AZ に非対応で、東京リージョンでは apne1-az3 が対象外です。
  EOT
  type        = list(string)
  default     = ["apne1-az3"]
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
