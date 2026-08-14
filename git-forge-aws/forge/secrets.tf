#
# 秘匿値の置き場。
# 平文のパスワードは tfvars にも cloud-init にも書きません。
# Terraform が生成 → Secrets Manager に保存 → インスタンスが IAM 権限で読む、という流れです。
#
# 注意: 生成したパスワードは tfstate にも保存されます。tfstate を S3 + KMS に置き、
#       アクセスできる人を絞ることが前提の設計です（bootstrap スタックがその役割）。
#

resource "random_password" "admin" {
  length  = 32
  special = true
  # Forgejo の CLI 引数として渡すためシェルで扱いにくい文字は除外する
  override_special = "!#%*-_=+?"
}

resource "aws_secretsmanager_secret" "admin" {
  name                    = "${var.project}/forge/admin"
  description             = "${var.project} forge initial admin credentials"
  kms_key_id              = aws_kms_key.forge.arn
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "admin" {
  secret_id = aws_secretsmanager_secret.admin.id

  secret_string = jsonencode({
    username = var.admin_username
    password = random_password.admin.result
    email    = var.admin_email
    url      = "https://${var.domain_name}/"
  })
}
