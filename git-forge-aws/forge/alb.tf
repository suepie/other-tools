#
# ALB + ACM + Route 53。
# TLS 証明書は ACM の DNS 検証で自動発行・自動更新されるため、
# インスタンス側で証明書を持つ必要がありません（管理する秘密が 1 つ減ります）。
#

resource "aws_acm_certificate" "forge" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.forge.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "forge" {
  certificate_arn         = aws_acm_certificate.forge.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

resource "aws_lb" "forge" {
  name               = "${var.project}-forge"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  # Git の push は大きくなりうるのでアイドルタイムアウトを延ばす
  idle_timeout = 300

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

  # 起動直後のヘルスチェック失敗を許容する
  deregistration_delay = 30
}

resource "aws_lb_target_group_attachment" "forge" {
  target_group_arn = aws_lb_target_group.forge.arn
  target_id        = aws_instance.forge.id
  port             = 3000
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.forge.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.forge.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.forge.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.forge.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_route53_record" "forge" {
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.forge.dns_name
    zone_id                = aws_lb.forge.zone_id
    evaluate_target_health = true
  }
}
