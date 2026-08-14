#
# ストレージ。役割ごとに置き場所を分けています。
#
#   EFS : ベア Git リポジトリと app.ini（ファイルシステムが必須なもの）
#   S3  : LFS / 添付 / アバター / Packages / Actions のログと成果物
#         （Forgejo 公式が性能上の理由で外部オブジェクトストレージを推奨している部分）
#   RDS : メタデータ全般（SQLite は NFS 上でロックが壊れるため使わない）
#

# ---- KMS -----------------------------------------------------------------

# プロジェクト専用の CMK。EFS / S3 / RDS / Secrets をこれで暗号化することで、
# 「鍵を分ける = プロジェクトを分ける」を担保します。
resource "aws_kms_key" "forge" {
  description             = "${var.project} forge data encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "forge" {
  name          = "alias/${var.project}-forge"
  target_key_id = aws_kms_key.forge.key_id
}

# ---- EFS -----------------------------------------------------------------

resource "aws_efs_file_system" "forge" {
  creation_token = "${var.project}-forge"
  encrypted      = true
  kms_key_id     = aws_kms_key.forge.arn

  # Git は小さいファイルへのアクセスが多い。Elastic にしてスループット上限で詰まらせない
  throughput_mode = "elastic"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  lifecycle_policy {
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }

  tags = { Name = "${var.project}-forge" }
}

resource "aws_efs_mount_target" "forge" {
  count = length(aws_subnet.public)

  file_system_id  = aws_efs_file_system.forge.id
  subnet_id       = aws_subnet.public[count.index].id
  security_groups = [aws_security_group.efs.id]
}

# Forgejo はコンテナ内で uid/gid 1000 で動くので、アクセスポイントで固定する
resource "aws_efs_access_point" "forge" {
  file_system_id = aws_efs_file_system.forge.id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/forgejo"

    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }

  tags = { Name = "${var.project}-forge-data" }
}

# EFS のバックアップ（AWS Backup の既定プラン）
resource "aws_efs_backup_policy" "forge" {
  file_system_id = aws_efs_file_system.forge.id

  backup_policy {
    status = "ENABLED"
  }
}

# ---- S3 ------------------------------------------------------------------

resource "aws_s3_bucket" "objects" {
  bucket = "${var.project}-forge-objects-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "objects" {
  bucket                  = aws_s3_bucket.objects.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "objects" {
  bucket = aws_s3_bucket.objects.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.forge.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "objects" {
  bucket = aws_s3_bucket.objects.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "objects" {
  bucket = aws_s3_bucket.objects.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.objects.arn,
        "${aws_s3_bucket.objects.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

# ---- RDS -----------------------------------------------------------------

resource "aws_db_subnet_group" "forge" {
  name       = "${var.project}-forge"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "forge" {
  identifier     = "${var.project}-forge"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_allocated_storage * 4
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.forge.arn

  db_name  = "forgejo"
  username = "forgejo"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.forge.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  backup_retention_period = var.db_backup_retention_days
  backup_window           = "18:00-19:00" # JST 03:00-04:00
  maintenance_window      = "sun:19:00-sun:20:00"

  auto_minor_version_upgrade = true
  deletion_protection        = true
  skip_final_snapshot        = false
  final_snapshot_identifier  = "${var.project}-forge-final"

  performance_insights_enabled = false

  tags = { Name = "${var.project}-forge" }
}
