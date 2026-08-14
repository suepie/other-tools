#
# IAM。ECS Managed Instances は 2 種類のロールを要求します。
#
#   infrastructure role : ECS が「あなたの代わりに」インスタンスを起動・管理するためのロール
#   instance profile    : 起動されたインスタンス自身が使うロール（ECS エージェント / SSM）
#
# これに加えてタスク側で 2 つ。
#   execution role : イメージ取得と Secrets Manager からの値注入（ECS エージェントが使う）
#   task role      : コンテナ自身が使う権限（EFS など）
#

data "aws_iam_policy_document" "assume_ecs" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "assume_ecs_tasks" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ---- Managed Instances のインフラロール ----------------------------------

resource "aws_iam_role" "ecs_infrastructure" {
  name               = "${var.project}-ecs-infrastructure"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs.json
}

# ★このマネージドポリシー名は ECS Managed Instances 用のものです。
#   apply が権限エラーになる場合は、AWS のドキュメントで現行のポリシー名を確認してください。
resource "aws_iam_role_policy_attachment" "ecs_infrastructure" {
  role       = aws_iam_role.ecs_infrastructure.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForManagedInstances"
}

# ---- インスタンス自身のロール --------------------------------------------

resource "aws_iam_role" "ecs_instance" {
  name               = "${var.project}-ecs-instance"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy_attachment" "ecs_instance_ecs" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# トラブルシュート時にセッションで入れるようにしておく（SSH 鍵は作らない）
resource "aws_iam_role_policy_attachment" "ecs_instance_ssm" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name = "${var.project}-ecs-instance"
  role = aws_iam_role.ecs_instance.name
}

# ---- タスク実行ロール ----------------------------------------------------

resource "aws_iam_role" "task_execution" {
  name               = "${var.project}-forge-task-execution"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Secrets Manager の値をコンテナ環境変数に注入するのは実行ロールの仕事
data "aws_iam_policy_document" "task_execution_secrets" {
  statement {
    sid       = "ReadAppSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.app.arn]
  }

  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.forge.arn]
  }
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name   = "${var.project}-forge-task-execution-secrets"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution_secrets.json
}

# ---- タスクロール --------------------------------------------------------

resource "aws_iam_role" "task" {
  name               = "${var.project}-forge-task"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
}

data "aws_iam_policy_document" "task" {
  # ECS Exec（aws ecs execute-command）でコンテナに入るために必要
  statement {
    sid = "EcsExec"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }

  statement {
    sid = "MountEfs"
    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
      "elasticfilesystem:ClientRootAccess",
    ]
    resources = [aws_efs_file_system.forge.arn]

    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:AccessPointArn"
      values   = [aws_efs_access_point.forge.arn]
    }
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "${var.project}-forge-task"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}
