#
# KMS / EBS / IAM / EC2。
# データボリュームはインスタンスとは別リソースにしてあるので、
# インスタンスを作り直してもリポジトリは残ります。
#

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# ---- KMS -----------------------------------------------------------------

# プロジェクトごとの CMK。EBS と Secrets Manager をこれで暗号化することで、
# 「鍵を分ける = プロジェクトを分ける」という分離の担保になります。
resource "aws_kms_key" "forge" {
  description             = "${var.project} forge data encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "forge" {
  name          = "alias/${var.project}-forge"
  target_key_id = aws_kms_key.forge.key_id
}

# ---- データボリューム ----------------------------------------------------

resource "aws_ebs_volume" "data" {
  availability_zone = aws_subnet.public[0].availability_zone
  size              = var.data_volume_size
  type              = var.data_volume_type
  encrypted         = true
  kms_key_id        = aws_kms_key.forge.arn

  tags = { Name = "${var.project}-forge-data" }

  # リポジトリ本体。誤って消さないよう明示的に守る
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.forge.id
}

# ---- IAM -----------------------------------------------------------------

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.project}-forge-instance"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

# SSM Session Manager でのアクセスに必要（SSH 鍵を作らずに済む理由）
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid       = "ReadAdminSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.admin.arn]
  }

  statement {
    sid       = "UseForgeKey"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.forge.arn]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "${var.project}-forge-instance"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.project}-forge-instance"
  role = aws_iam_role.instance.name
}

# ---- EC2 -----------------------------------------------------------------

resource "aws_instance" "forge" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  # イメージ取得と SSM のためにパブリック IP を持たせる（NAT Gateway を省くため）。
  # インバウンドは SG で ALB からのみに絞っているので外部から直接は繋がりません。
  associate_public_ip_address = true

  # SSH 鍵は意図的に指定しません。アクセスは SSM Session Manager 経由です。
  # key_name = ...

  metadata_options {
    http_tokens                 = "required" # IMDSv2 必須
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2 # コンテナからの取得を許容
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = aws_kms_key.forge.arn
  }

  user_data = templatefile("${path.module}/templates/cloud-init.sh.tftpl", {
    # EBS の NVMe デバイスは by-id で確実に特定する（ボリューム ID からハイフンを除いた形）
    volume_nvme_id = replace(aws_ebs_volume.data.id, "-", "")
    region         = var.region
    secret_arn     = aws_secretsmanager_secret.admin.arn
    forge_image    = var.forge_image
    runner_image   = var.runner_image
    runner_labels  = var.runner_labels
    enable_runner  = var.enable_runner
    domain         = var.domain_name
    root_url       = "https://${var.domain_name}/"
    admin_username = var.admin_username
    admin_email    = var.admin_email
  })

  # user_data を変えてもインスタンスは自動では作り直されません（データ保護のため）。
  # 反映したいときは `terraform taint aws_instance.forge` などで明示的に置き換えてください。
  user_data_replace_on_change = false

  tags = { Name = "${var.project}-forge" }
}
