#
# ネットワーク。
#   public  : ECS インスタンス / EFS マウントターゲット（イメージ取得のため外向き通信が要る）
#   private : 内部 ALB / RDS / CloudFront VPC オリジンの ENI
#
# 入口は CloudFront だけです。ALB は internal なのでインターネットからは到達できません。
# 固定 IP による制限は CloudFront 側の WAF で行います（cloudfront.tf）。
#

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # CloudFront VPC オリジンが非対応の AZ を除外する。
  # 東京では apne1-az3 が対象外で、そこに ALB を置くと VPC オリジンを作れません。
  usable_azs = [
    for i, name in data.aws_availability_zones.available.names :
    name if !contains(var.excluded_az_ids, data.aws_availability_zones.available.zone_ids[i])
  ]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

# VPC オリジンの前提条件。ルーティングには使われませんが、
# 「この VPC はインターネットからのトラフィックを受けられる」ことを示すために必須です。
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.usable_azs[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${local.name_prefix}-public-${count.index}" }
}

# 内部 ALB / RDS / CloudFront の ENI を置く。インターネットへの経路は持たせない
resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.usable_azs[count.index]

  tags = { Name = "${local.name_prefix}-private-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${local.name_prefix}-public" }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# S3 へのゲートウェイエンドポイント。
# Forgejo が LFS / 添付 / Packages / Actions 成果物を読み書きする通信を、
# インターネット経由ではなく AWS 内部の経路に閉じます。
# ゲートウェイ型は追加料金がかかりません。
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]

  tags = { Name = "${local.name_prefix}-s3" }
}

# ---- セキュリティグループ ------------------------------------------------

# CloudFront のオリジン向け IP レンジ。VPC オリジンからの通信をこれで許可する
data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb"
  description = "Internal ALB, reachable only from CloudFront VPC origin"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-alb" }
}

# CloudFront 以外からは届きません。
# より厳しくするなら、VPC オリジン作成後に自動生成される
# CloudFront-VPCOrigins-Service-SG からのみ許可する形に変更できます。
resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from CloudFront VPC origin"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_instance" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to ECS instances"
  referenced_security_group_id = aws_security_group.instance.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

# ECS Managed Instances が起動するインスタンス
resource "aws_security_group" "instance" {
  name        = "${local.name_prefix}-ecs-instance"
  description = "ECS managed instances for forge and runner"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-ecs-instance" }
}

resource "aws_vpc_security_group_ingress_rule" "instance_from_alb" {
  security_group_id            = aws_security_group.instance.id
  description                  = "Forge HTTP from ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "instance_all" {
  security_group_id = aws_security_group.instance.id
  description       = "Outbound for image pull / AWS APIs / CI"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# EFS: インスタンスからの NFS のみ
resource "aws_security_group" "efs" {
  name        = "${local.name_prefix}-efs"
  description = "EFS mount targets"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-efs" }
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_instance" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from ECS instances"
  referenced_security_group_id = aws_security_group.instance.id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
}

# RDS: インスタンスからの PostgreSQL のみ
resource "aws_security_group" "db" {
  name        = "${local.name_prefix}-db"
  description = "RDS PostgreSQL"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-db" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_instance" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from ECS instances"
  referenced_security_group_id = aws_security_group.instance.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
