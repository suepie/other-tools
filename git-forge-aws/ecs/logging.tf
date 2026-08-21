#
# 監査ログ。
#
#   CloudFront アクセスログ → S3   誰がどの URL にアクセスしたか
#   ALB アクセスログ        → S3   オリジンに到達したリクエスト
#   WAF ログ               → CloudWatch Logs (us-east-1)  許可/拒否の判定結果
#
# ★このバケットだけは AES256（SSE-S3）で暗号化します。
#   CloudFront と ALB のログ配信はカスタマー管理 KMS キーに対応しておらず、
#   CMK を指定すると配信が失敗するためです。
#

# ---- ログ用 S3 バケット ---------------------------------------------------

resource "aws_s3_bucket" "logs" {
  bucket = "${local.name_prefix}-logs-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudFront のログ配信は ACL でバケットに書き込むため、ACL を有効にしておく必要があります。
# 既定の BucketOwnerEnforced のままだと配信できません。
resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = var.access_log_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ALB のログ配信元。リージョンによって「ELB のアカウント」と
# 「サービスプリンシパル」のどちらかが使われるため、両方許可しておきます。
data "aws_elb_service_account" "main" {}

data "aws_iam_policy_document" "logs" {
  statement {
    sid       = "AlbLogDeliveryAccount"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/alb/*"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main.arn]
    }
  }

  statement {
    sid       = "AlbLogDeliveryService"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/alb/*"]

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }
  }

  statement {
    sid       = "AlbLogDeliveryAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.logs.arn]

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs.json

  depends_on = [aws_s3_bucket_public_access_block.logs]
}

# ---- WAF ログ -------------------------------------------------------------
#
# CLOUDFRONT スコープの WebACL なので、ログ出力先も us-east-1 に置きます。
# ロググループ名は aws-waf-logs- で始まる必要があります（WAF 側の制約）。
#
# CMK は ap-northeast-1 にあり us-east-1 のロググループには使えないため、
# ここは AWS 管理キーでの保存時暗号化になります。

resource "aws_cloudwatch_log_group" "waf" {
  provider = aws.us_east_1

  name              = "aws-waf-logs-${local.name_prefix}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "waf_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:aws-waf-logs-*:*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "waf" {
  provider = aws.us_east_1

  policy_name     = "${local.name_prefix}-waf-logs"
  policy_document = data.aws_iam_policy_document.waf_logs.json
}

resource "aws_wafv2_web_acl_logging_configuration" "forge" {
  provider = aws.us_east_1

  resource_arn            = aws_wafv2_web_acl.forge.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # 認証ヘッダと Cookie はログに残さない
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }

  depends_on = [aws_cloudwatch_log_resource_policy.waf]
}
