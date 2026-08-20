#
# CloudFront（VPC オリジン）+ WAF。
#
# 独自ドメインを持たずに正規の TLS を張るための構成です。
# CloudFront の既定ドメイン（*.cloudfront.net）には有効な証明書が最初から付いています。
# ACM は *.elb.amazonaws.com の証明書を発行できないため、ALB を直接公開する方式では
# HTTPS にできません。CloudFront を挟むことでそれを回避しています。
#
# VPC オリジンにより、ALB は internal のままで CloudFront からのみ到達できます。
# 固定 IP による制限は WAF（CLOUDFRONT スコープ）で行います。
#

locals {
  forge_host     = aws_cloudfront_distribution.forge.domain_name
  forge_root_url = "https://${aws_cloudfront_distribution.forge.domain_name}/"
}

# ---- VPC オリジン --------------------------------------------------------

resource "aws_cloudfront_vpc_origin" "forge" {
  vpc_origin_endpoint_config {
    name                   = local.name_prefix
    arn                    = aws_lb.forge.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  # 作成に最大 15 分かかる
  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  tags = { Name = "${local.name_prefix}" }
}

# ---- WAF（IP 制限） ------------------------------------------------------
# CLOUDFRONT スコープの WAF は us-east-1 にしか作れない

resource "aws_wafv2_ip_set" "allowed" {
  provider = aws.us_east_1

  name               = "${local.name_prefix}-allowed"
  description        = "Source IPs allowed to reach ${local.name_prefix}"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = var.allowed_cidrs
}

resource "aws_wafv2_web_acl" "forge" {
  provider = aws.us_east_1

  name        = local.name_prefix
  description = "Allow only listed source IPs"
  scope       = "CLOUDFRONT"

  # 既定は拒否。許可リストに載っている送信元だけ通す
  default_action {
    block {}
  }

  rule {
    name     = "allow-listed-ips"
    priority = 1

    action {
      allow {}
    }

    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.allowed.arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.metric_prefix}AllowedIps"
      sampled_requests_enabled   = false
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.metric_prefix}Forge"
    sampled_requests_enabled   = false
  }
}

# ---- ディストリビューション ----------------------------------------------

# Git のレスポンスは絶対にキャッシュしてはいけない
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# 認証ヘッダ・Cookie・クエリをすべてオリジンへ転送する
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "forge" {
  enabled         = true
  comment         = local.name_prefix
  price_class     = var.cloudfront_price_class
  http_version    = "http2and3"
  web_acl_id      = aws_wafv2_web_acl.forge.arn
  is_ipv6_enabled = true

  origin {
    origin_id   = "forge-alb"
    domain_name = aws_lb.forge.dns_name

    vpc_origin_config {
      vpc_origin_id            = aws_cloudfront_vpc_origin.forge.id
      origin_read_timeout      = var.origin_read_timeout
      origin_keepalive_timeout = var.origin_keepalive_timeout
    }
  }

  default_cache_behavior {
    target_origin_id       = "forge-alb"
    viewer_protocol_policy = "redirect-to-https"

    # Git smart HTTP は git-upload-pack / git-receive-pack へ POST する
    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    # キャッシュ無効化は必須。有効だと Git の応答が壊れる
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id

    compress = false
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # 既定ドメイン（*.cloudfront.net）の証明書を使う。独自ドメイン不要
  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1.2_2021"
  }

  tags = { Name = "${local.name_prefix}" }
}
