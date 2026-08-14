#
# データボリュームの日次スナップショット。
# Git サーバをバックアップなしで運用しないための最低限の仕組みです。
# スナップショットは EBS と同じ CMK で暗号化されます。
#

data "aws_iam_policy_document" "assume_dlm" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "${var.project}-forge-dlm"
  assume_role_policy = data.aws_iam_policy_document.assume_dlm.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

# CMK で暗号化されたボリュームのスナップショットを取るため、DLM に鍵の使用を許可する
resource "aws_kms_grant" "dlm" {
  name              = "${var.project}-forge-dlm"
  key_id            = aws_kms_key.forge.arn
  grantee_principal = aws_iam_role.dlm.arn

  operations = [
    "CreateGrant",
    "Decrypt",
    "DescribeKey",
    "Encrypt",
    "GenerateDataKey",
    "GenerateDataKeyWithoutPlaintext",
    "ReEncryptFrom",
    "ReEncryptTo",
  ]
}

resource "aws_dlm_lifecycle_policy" "forge_data" {
  description        = "${var.project} forge data volume daily snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    # 対象はデータボリュームのみ（ルートは使い捨て前提）
    target_tags = {
      Name = "${var.project}-forge-data"
    }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = [var.backup_time_utc]
      }

      retain_rule {
        count = var.backup_retention_count
      }

      copy_tags = true

      tags_to_add = {
        SnapshotCreator = "dlm"
        Project         = var.project
      }
    }
  }

  depends_on = [aws_iam_role_policy_attachment.dlm]
}
