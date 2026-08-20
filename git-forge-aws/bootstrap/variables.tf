variable "project" {
  description = "プロジェクト識別子。リソース名の接頭辞になります（英小文字・数字・ハイフン）"
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

variable "aws_profile" {
  description = <<-EOT
    使用する AWS プロファイル名。指定すると環境変数 AWS_PROFILE に依存しなくなります。
    空にすると通常どおり環境変数や既定のプロファイルを見ます。ecs 側と同じ値にしてください。
  EOT
  type        = string
  default     = ""
}

variable "allowed_account_ids" {
  description = <<-EOT
    このスタックを適用してよい AWS アカウント ID のリスト。
    指定すると、別アカウントの認証情報で実行したときにエラーで止まります。
    ecs/ 側と同じ値にしてください。空にするとチェックしません。
  EOT
  type        = list(string)
  default     = []
}
