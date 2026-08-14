#
# ネットワーク。
#   public  : ALB / ECS インスタンス / EFS マウントターゲット
#   private : RDS のみ（アウトバウンド不要なので NAT Gateway を置かずに済む）
#
# ECS インスタンスはイメージ取得と AWS API 呼び出しのためパブリックサブネットに置きますが、
# インバウンドは ALB のセキュリティグループからのみ許可しています。
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

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project}-public-${count.index}" }
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "${var.project}-private-${count.index}" }
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

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP (redirect) from allowed source"
  cidr_ipv4         = each.value
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

# ECS Managed Instances が起動するインスタンスに付くセキュリティグループ
resource "aws_security_group" "instance" {
  name        = "${var.project}-ecs-instance"
  description = "ECS managed instances for forge and runner"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.project}-ecs-instance" }
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
  name        = "${var.project}-efs"
  description = "EFS mount targets"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.project}-efs" }
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
  name        = "${var.project}-db"
  description = "RDS PostgreSQL"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.project}-db" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_instance" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from ECS instances"
  referenced_security_group_id = aws_security_group.instance.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
