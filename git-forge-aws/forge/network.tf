#
# ネットワーク。
# EC2 はパブリックサブネットに置きますが、インバウンドは ALB のセキュリティグループ
# からのみ許可するため、実質的に外からは閉じています。
# NAT Gateway を置かずに済ませるための構成で、コストと引き換えの割り切りです。
# より堅くするならプライベートサブネット + NAT または VPC エンドポイントに変更してください。
#

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.project}-igw" }
}

# ALB は 2 AZ 以上のサブネットを要求するため 2 つ作る
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${var.project}-public-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.project}-public" }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---- セキュリティグループ ------------------------------------------------

# ALB: 許可した固定 IP からの 80/443 のみ
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb"
  description = "Forge ALB: allow only listed source CIDRs"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.project}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from allowed source"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# 80 は 443 へのリダイレクト専用（同じ IP 制限を掛ける）
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP (redirect to HTTPS) from allowed source"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_instance" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to forge instance"
  referenced_security_group_id = aws_security_group.instance.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

# インスタンス: ALB からのみ受ける。SSH ポートは開けない（アクセスは SSM 経由）
resource "aws_security_group" "instance" {
  name        = "${var.project}-instance"
  description = "Forge instance: only from ALB"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.project}-instance" }
}

resource "aws_vpc_security_group_ingress_rule" "instance_from_alb" {
  security_group_id            = aws_security_group.instance.id
  description                  = "Forge HTTP from ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

# コンテナイメージの取得、OS 更新、SSM、Actions のためアウトバウンドは開ける
resource "aws_vpc_security_group_egress_rule" "instance_all" {
  security_group_id = aws_security_group.instance.id
  description       = "Outbound for image pull / updates / SSM"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
