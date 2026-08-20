#
# 内部 ALB。
#
# インターネットからは到達できません（internal かつプライベートサブネット）。
# 唯一の経路は CloudFront VPC オリジンで、そこから HTTP で受けます。
# TLS の終端は CloudFront 側で行うため、ここに証明書は不要です。
#

resource "aws_lb" "forge" {
  name               = "${var.project}-forge"
  load_balancer_type = "application"
  internal           = true
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.private[*].id

  # Git の push は時間がかかりうるのでアイドルタイムアウトを延ばす。
  # CloudFront 側の origin_read_timeout より長くしておく
  idle_timeout               = 300
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "forge" {
  name        = "${var.project}-forge"
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
