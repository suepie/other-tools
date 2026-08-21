#
# 内部 ALB。
#
# インターネットからは到達できません（internal かつプライベートサブネット）。
# 唯一の経路は CloudFront VPC オリジンで、そこから HTTP で受けます。
# TLS の終端は CloudFront 側で行うため、ここに証明書は不要です。
#

resource "aws_lb" "forge" {
  name               = local.name_prefix
  load_balancer_type = "application"
  internal           = true
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.private[*].id

  # Git の push は時間がかかりうるのでアイドルタイムアウトを延ばす。
  # CloudFront 側の origin_read_timeout より長くしておく
  idle_timeout               = 300
  drop_invalid_header_fields = true

  # オリジンに到達したリクエストの記録
  access_logs {
    bucket  = aws_s3_bucket.logs.id
    prefix  = "alb"
    enabled = true
  }

  # ALB とターゲットグループの名前は 32 文字までという制約がある。
  # AWS 側の分かりにくいエラーになる前に、plan の段階で止める。
  lifecycle {
    precondition {
      condition     = length(local.name_prefix) <= 32
      error_message = "project と component を合わせた長さ（ハイフン込み）が 32 文字を超えています（現在 ${length(local.name_prefix)} 文字）。ALB 名の上限です。短くしてください。"
    }
  }

  # ALB は作成時にログバケットへ書き込みテストを行います。
  # bucket を参照しているだけではポリシーとの順序が保証されず、
  # ポリシー適用前に作られて「Please check S3bucket permission」になります。
  depends_on = [
    aws_s3_bucket_policy.logs,
    aws_s3_bucket_ownership_controls.logs,
    aws_s3_bucket_server_side_encryption_configuration.logs,
  ]
}

resource "aws_lb_target_group" "forge" {
  name        = local.name_prefix
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "instance"

  health_check {
    path                = "/api/healthz"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.forge.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.forge.arn
  }
}
