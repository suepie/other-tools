#
# ネットワーク。
#   public  : NAT Gateway のみ（IGW への経路を持つ唯一のサブネット）
#   private : ECS インスタンス / 内部 ALB / RDS / EFS / CloudFront VPC オリジンの ENI
#
# ワークロードはすべてプライベートサブネットにあり、パブリック IP を持ちません。
# 外向き通信（イメージ取得・AWS API・CI）は NAT Gateway 経由です。
# 入口は CloudFront だけで、固定 IP 制限は WAF で行います（cloudfront.tf）。
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

# VPC オリジンの前提条件でもあります。ルーティングには使われませんが、
# 「この VPC はインターネットからのトラフィックを受けられる」ことを示すために必須です。
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-igw" }
}

# ---- サブネット ----------------------------------------------------------

# NAT Gateway を置くためだけのサブネット。ここにワークロードは置きません。
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.usable_azs[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${local.name_prefix}-public-${count.index}" }
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.usable_azs[count.index]

  tags = { Name = "${local.name_prefix}-private-${count.index}" }
}

# ---- NAT Gateway ---------------------------------------------------------

resource "aws_eip" "nat" {
  count = var.nat_gateway_count

  domain = "vpc"

  tags = { Name = "${local.name_prefix}-nat-${count.index}" }
}

resource "aws_nat_gateway" "this" {
  count = var.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "${local.name_prefix}-nat-${count.index}" }

  depends_on = [aws_internet_gateway.this]
}

# ---- ルートテーブル ------------------------------------------------------

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

# プライベート側は AZ ごとにルートテーブルを持ちます。
# NAT が 1 台のときは両 AZ とも同じ NAT を向きます（AZ 間通信料が少し発生します）。
resource "aws_route_table" "private" {
  count = length(aws_subnet.private)

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[min(count.index, var.nat_gateway_count - 1)].id
  }

  tags = { Name = "${local.name_prefix}-private-${count.index}" }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# S3 へのゲートウェイエンドポイント。
# Forgejo が LFS / 添付 / Packages / Actions 成果物を読み書きする通信を
# NAT とインターネットを経由させず、AWS 内部の経路に閉じます。
# ゲートウェイ型は追加料金がかからず、NAT のデータ処理料も節約できます。
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

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

# CI がパッケージレジストリやコンテナレジストリに出られないと機能しないため開けています。
# 経路は NAT Gateway 経由で、インスタンス自体はパブリック IP を持ちません。
resource "aws_vpc_security_group_egress_rule" "instance_all" {
  security_group_id = aws_security_group.instance.id
  description       = "Outbound via NAT for image pull / AWS APIs / CI"
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
