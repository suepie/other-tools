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
