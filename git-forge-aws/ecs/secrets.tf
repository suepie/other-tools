#
# 秘匿値の置き場。ここが「鍵をどこに入れるか」の答えです。
#
#   1. Terraform が生成する            → Secrets Manager に保存（CMK で暗号化）
#   2. ECS タスクは IAM ロールで読む   → コンテナ定義には ARN しか書かない
#   3. tfvars にも user_data にも平文は書かない
#
# 生成した値は tfstate にも入ります。tfstate を S3 + KMS に置き、
# 参照できる人を絞ることが前提の設計です（bootstrap スタックがその役割）。
#

data "aws_caller_identity" "current" {}

# ---- DB パスワード -------------------------------------------------------

resource "random_password" "db" {
  length  = 40
  special = false # RDS と接続文字列で扱いやすいよう英数字のみ
}

# ---- 管理者パスワード ----------------------------------------------------

resource "random_password" "admin" {
  length           = 32
  special          = true
  override_special = "!#%*-_=+?"
}

# ---- Actions ランナー登録用の共有シークレット ----------------------------
# Forgejo 側と runner 側に同じ値を渡すことで、UI でトークンを発行せずに
# 宣言的にランナーを登録できます（40 桁の 16 進数である必要があります）。

resource "random_id" "runner_secret" {
  byte_length = 20
}

# ---- S3 アクセスキー -----------------------------------------------------
#
# ★ここだけ長期クレデンシャルが必要です。
#   Forgejo（Gitea 系）の S3 クライアントは IAM ロールの資格情報チェーンに未対応で、
#   アクセスキーとシークレットの指定が必須です（go-gitea/gitea#32271）。
#   そのため専用の IAM ユーザーを作り、このバケットにだけ権限を絞っています。
#   将来 Forgejo が IAM ロールに対応したら、このユーザーは削除できます。

resource "aws_iam_user" "s3" {
  name = "${var.project}-forge-s3"
  path = "/service/"
}

data "aws_iam_policy_document" "s3_user" {
  statement {
    sid = "BucketLevel"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [aws_s3_bucket.objects.arn]
  }

  statement {
    sid = "ObjectLevel"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.objects.arn}/*"]
  }

  statement {
    sid = "UseKey"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [aws_kms_key.forge.arn]
  }
}

resource "aws_iam_user_policy" "s3" {
  name   = "${var.project}-forge-s3"
  user   = aws_iam_user.s3.name
  policy = data.aws_iam_policy_document.s3_user.json
}

resource "aws_iam_access_key" "s3" {
  user = aws_iam_user.s3.name
}

# ---- Secrets Manager -----------------------------------------------------

# アプリが起動時に読む値をまとめる。ECS のコンテナ定義からは JSON キー単位で参照する
resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.project}/forge/app"
  description             = "${var.project} forge runtime secrets"
  kms_key_id              = aws_kms_key.forge.arn
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id

  secret_string = jsonencode({
    db_password    = random_password.db.result
    s3_access_key  = aws_iam_access_key.s3.id
    s3_secret_key  = aws_iam_access_key.s3.secret
    runner_secret  = random_id.runner_secret.hex
    admin_password = random_password.admin.result
  })
}

# 人間が取り出す用（初期ログイン情報）。上とは用途を分けておく
resource "aws_secretsmanager_secret" "admin" {
  name                    = "${var.project}/forge/admin"
  description             = "${var.project} forge initial admin login"
  kms_key_id              = aws_kms_key.forge.arn
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "admin" {
  secret_id = aws_secretsmanager_secret.admin.id

  secret_string = jsonencode({
    url      = local.forge_root_url
    username = var.admin_username
    password = random_password.admin.result
    email    = var.admin_email
  })
}
