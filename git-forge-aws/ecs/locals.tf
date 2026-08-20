#
# リソース名の接頭辞。
#
# 同じアカウントに別のスタックを置いても見分けが付くよう、
# 「プロジェクト名 + 用途」で組み立てます。既定では project-a-git のようになります。
#

locals {
  name_prefix = "${var.project}-${var.component}"

  # WAF のメトリクス名は英数字のみ
  metric_prefix = replace(local.name_prefix, "-", "")
}
