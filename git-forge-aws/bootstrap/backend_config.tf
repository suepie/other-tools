#
# ecs/backend.hcl の自動生成。
#
# 以前は `terraform output -raw backend_config > ../ecs/backend.hcl` を
# 手で実行する手順でしたが、実行し忘れや実行ディレクトリの間違いが起きやすいため、
# bootstrap の apply 時に直接書き出すようにしています。
#

locals {
  # S3 バックエンドはプロバイダとは別に認証を解決し、変数を参照できません。
  # そのため aws_profile を指定している場合は profile キーとして埋め込みます。
  # これがないと、環境変数が無いシェルで
  # "no valid credential sources found" になります。
  backend_config = join("\n", concat(
    [
      "bucket       = \"${aws_s3_bucket.tfstate.id}\"",
      "key          = \"forge/terraform.tfstate\"",
      "region       = \"${var.region}\"",
      "encrypt      = true",
      "kms_key_id   = \"${aws_kms_key.tfstate.arn}\"",
      "use_lockfile = true",
    ],
    var.aws_profile != "" ? ["profile      = \"${var.aws_profile}\""] : [],
  ))
}

resource "local_file" "backend_config" {
  filename = "${path.module}/../ecs/backend.hcl"
  content  = "${local.backend_config}\n"

  # バケット名など環境固有の情報が入るため、他人に読ませない
  file_permission = "0600"
}
