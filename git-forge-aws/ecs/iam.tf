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
  name               = "${local.name_prefix}-ecs-infrastructure"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs.json
}

resource "aws_iam_role_policy_attachment" "ecs_infrastructure" {
  role       = aws_iam_role.ecs_infrastructure.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForManagedInstances"
}

# マネージドポリシーには iam:PassRole が含まれていません。
# 渡す先のロール ARN は利用者ごとに違うため、AWS 側で定義できないからです。
#
# これが無いと ECS がインスタンスを起動できず、
#   UnauthorizedOperation: You are not authorized to perform iam:PassRole on ...
# となってタスクが配置されません（サービスは ACTIVE のまま running が 0）。
#
# 渡せるロールをインスタンスロール 1 つに限定しているので、これで十分絞れています。
# iam:PassedToService の条件は、ECS がどのサービス名で渡すかに依存して
# かえって拒否される可能性があるため付けていません。
data "aws_iam_policy_document" "ecs_infrastructure_passrole" {
  statement {
    sid       = "PassInstanceRoleToEc2"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.ecs_instance.arn]
  }
}

resource "aws_iam_role_policy" "ecs_infrastructure_passrole" {
  name   = "${local.name_prefix}-ecs-infrastructure-passrole"
  role   = aws_iam_role.ecs_infrastructure.id
  policy = data.aws_iam_policy_document.ecs_infrastructure_passrole.json
}

# ---- インスタンス自身のロール --------------------------------------------

resource "aws_iam_role" "ecs_instance" {
  name               = "${local.name_prefix}-ecs-instance"
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
  name = "${local.name_prefix}-ecs-instance"
  role = aws_iam_role.ecs_instance.name
}

# ---- タスク実行ロール ----------------------------------------------------

resource "aws_iam_role" "task_execution" {
  name               = "${local.name_prefix}-task-execution"
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
  name   = "${local.name_prefix}-task-execution-secrets"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution_secrets.json
}

# ---- タスクロール --------------------------------------------------------

resource "aws_iam_role" "task" {
  name               = "${local.name_prefix}-task"
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
    # ClientRootAccess は付けません。アクセスポイントで uid/gid 1000 を強制しており、
    # root としての書き込みは不要なためです。
    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
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
  name   = "${local.name_prefix}-task"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}
