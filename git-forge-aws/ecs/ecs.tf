#
# ECS クラスタ / Managed Instances キャパシティプロバイダ / タスク定義 / サービス。
#
# forge と runner を同じキャパシティプロバイダに載せています（構成の単純さを優先）。
# ネットワークモードは host にしているので、runner は http://localhost:3000 で
# forge に到達できます（内部 ALB や service discovery が不要になります）。
#

locals {
  # Secrets Manager の JSON からキー単位で注入するときの参照形式
  app_secret = aws_secretsmanager_secret.app.arn

  forge_env = [
    { name = "USER_UID", value = "1000" },
    { name = "USER_GID", value = "1000" },

    # インストールウィザードを飛ばす（管理者は bootstrap タスクで作成）
    { name = "FORGEJO__security__INSTALL_LOCK", value = "true" },

    { name = "FORGEJO__server__ROOT_URL", value = "https://${var.domain_name}/" },
    { name = "FORGEJO__server__DOMAIN", value = var.domain_name },
    { name = "FORGEJO__server__HTTP_PORT", value = "3000" },
    # Git は HTTPS のみ。SSH を閉じることで公開ポートを減らす
    { name = "FORGEJO__server__DISABLE_SSH", value = "true" },

    { name = "FORGEJO__database__DB_TYPE", value = "postgres" },
    { name = "FORGEJO__database__HOST", value = "${aws_db_instance.forge.address}:5432" },
    { name = "FORGEJO__database__NAME", value = aws_db_instance.forge.db_name },
    { name = "FORGEJO__database__USER", value = aws_db_instance.forge.username },
    { name = "FORGEJO__database__SSL_MODE", value = "require" },

    { name = "FORGEJO__service__DISABLE_REGISTRATION", value = "true" },
    { name = "FORGEJO__service__REQUIRE_SIGNIN_VIEW", value = "true" },

    { name = "FORGEJO__actions__ENABLED", value = "true" },

    # LFS / 添付 / アバター / Packages / Actions のログと成果物を S3 に逃がす。
    # ベア Git リポジトリはこの設定の対象外で、EFS 上に残ります。
    { name = "FORGEJO__storage__STORAGE_TYPE", value = "minio" },
    { name = "FORGEJO__storage__MINIO_ENDPOINT", value = "s3.${var.region}.amazonaws.com" },
    { name = "FORGEJO__storage__MINIO_BUCKET", value = aws_s3_bucket.objects.id },
    { name = "FORGEJO__storage__MINIO_LOCATION", value = var.region },
    { name = "FORGEJO__storage__MINIO_USE_SSL", value = "true" },
  ]

  forge_secrets = [
    { name = "FORGEJO__database__PASSWD", valueFrom = "${local.app_secret}:db_password::" },
    { name = "FORGEJO__storage__MINIO_ACCESS_KEY_ID", valueFrom = "${local.app_secret}:s3_access_key::" },
    { name = "FORGEJO__storage__MINIO_SECRET_ACCESS_KEY", valueFrom = "${local.app_secret}:s3_secret_key::" },
  ]
}

# ---- ログ ----------------------------------------------------------------

resource "aws_cloudwatch_log_group" "forge" {
  name              = "/ecs/${var.project}/forge"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.forge.arn
}

# ---- クラスタ ------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = "${var.project}-forge"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

# ---- Managed Instances キャパシティプロバイダ ----------------------------
#
# AWS がインスタンスの起動・スケーリング・パッチ適用（14日ごとの入れ替え）を代行します。
# EC2 と同じ能力を持つので、runner が必要とする docker.sock のマウントも使えます。

resource "aws_ecs_capacity_provider" "managed" {
  name    = "${var.project}-managed"
  cluster = aws_ecs_cluster.this.name

  managed_instances_provider {
    infrastructure_role_arn = aws_iam_role.ecs_infrastructure.arn
    propagate_tags          = "CAPACITY_PROVIDER"

    instance_launch_template {
      ec2_instance_profile_arn = aws_iam_instance_profile.ecs_instance.arn
      monitoring               = "BASIC"

      network_configuration {
        subnets         = aws_subnet.public[*].id
        security_groups = [aws_security_group.instance.id]
      }

      instance_requirements {
        vcpu_count {
          min = var.instance_vcpu_min
        }

        memory_mib {
          min = var.instance_memory_mib_min
        }

        cpu_manufacturers     = var.cpu_manufacturers
        burstable_performance = "included"
      }

      storage_configuration {
        storage_size_gib = var.instance_storage_gib
      }
    }
  }

  depends_on = [aws_iam_role_policy_attachment.ecs_infrastructure]
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = [aws_ecs_capacity_provider.managed.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.managed.name
    weight            = 1
    base              = 1
  }
}

# ---- Forgejo 本体 --------------------------------------------------------

resource "aws_ecs_task_definition" "forge" {
  family             = "${var.project}-forge"
  network_mode       = "host"
  execution_role_arn = aws_iam_role.task_execution.arn
  task_role_arn      = aws_iam_role.task.arn

  requires_compatibilities = ["EC2"]

  volume {
    name = "forge-data"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.forge.id
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = aws_efs_access_point.forge.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name              = "forgejo"
      image             = var.forge_image
      essential         = true
      memory            = 2048
      memoryReservation = 1024

      environment = local.forge_env
      secrets     = local.forge_secrets

      portMappings = [
        { containerPort = 3000, hostPort = 3000, protocol = "tcp" },
      ]

      mountPoints = [
        { sourceVolume = "forge-data", containerPath = "/data", readOnly = false },
      ]

      healthCheck = {
        # Forgejo のイメージは busybox 由来の wget を持つ
        command     = ["CMD-SHELL", "wget -q --spider http://localhost:3000/api/healthz || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 5
        startPeriod = 120
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.forge.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "forgejo"
        }
      }
    },
  ])
}

resource "aws_ecs_service" "forge" {
  name            = "${var.project}-forge"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.forge.arn
  desired_count   = 1

  # トラブル時にコンテナへ入れるようにしておく（SSH 鍵は不要）
  enable_execute_command = true

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.managed.name
    weight            = 1
    base              = 1
  }

  # EFS + RDS を持つステートフルなサービスなので、常に 1 タスクだけ動かす
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  load_balancer {
    target_group_arn = aws_lb_target_group.forge.arn
    container_name   = "forgejo"
    container_port   = 3000
  }

  depends_on = [
    aws_lb_listener.https,
    aws_ecs_cluster_capacity_providers.this,
  ]
}

# ---- Actions ランナー ----------------------------------------------------
#
# forge と同じインスタンス上で動き、http://localhost:3000 で forge に接続します。
# docker.sock をマウントするのでジョブごとにコンテナを起動できます
# （Fargate ではこれができないため Managed Instances を選んでいます）。

resource "aws_ecs_task_definition" "runner" {
  count = var.enable_runner ? 1 : 0

  family             = "${var.project}-forge-runner"
  network_mode       = "host"
  execution_role_arn = aws_iam_role.task_execution.arn
  task_role_arn      = aws_iam_role.task.arn

  requires_compatibilities = ["EC2"]

  volume {
    name      = "docker-sock"
    host_path = "/var/run/docker.sock"
  }

  volume {
    name = "runner-data"
  }

  container_definitions = jsonencode([
    {
      name              = "runner"
      image             = var.runner_image
      essential         = true
      memory            = 1536
      memoryReservation = 512

      # forge が起動するまで登録を再試行し、成功したらデーモンを起動する。
      # 共有シークレット方式なので、インスタンスが入れ替わっても同じ ID で再登録されます。
      entryPoint = ["/bin/sh", "-c"]
      command = [
        join(" ", [
          "set -e;",
          "mkdir -p /data;",
          "printf 'runner:\\n  labels:\\n' > /data/config.yaml;",
          "for l in $(echo \"$RUNNER_LABELS\" | tr ',' ' '); do printf '    - %s\\n' \"$l\" >> /data/config.yaml; done;",
          "i=0;",
          "until forgejo-runner create-runner-file --instance http://localhost:3000 --secret \"$RUNNER_SECRET\"; do",
          "i=$((i+1)); [ $i -gt 60 ] && exit 1; echo 'waiting for forge...'; sleep 5;",
          "done;",
          "exec forgejo-runner daemon --config /data/config.yaml",
        ])
      ]

      workingDirectory = "/data"

      environment = [
        { name = "RUNNER_LABELS", value = var.runner_labels },
      ]

      secrets = [
        { name = "RUNNER_SECRET", valueFrom = "${local.app_secret}:runner_secret::" },
      ]

      mountPoints = [
        { sourceVolume = "docker-sock", containerPath = "/var/run/docker.sock", readOnly = false },
        { sourceVolume = "runner-data", containerPath = "/data", readOnly = false },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.forge.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "runner"
        }
      }
    },
  ])
}

resource "aws_ecs_service" "runner" {
  count = var.enable_runner ? 1 : 0

  name            = "${var.project}-forge-runner"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.runner[0].arn
  desired_count   = 1

  enable_execute_command = true

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.managed.name
    weight            = 1
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [
    aws_ecs_service.forge,
    aws_ecs_cluster_capacity_providers.this,
  ]
}

# ---- 初期セットアップ用の使い捨てタスク ----------------------------------
#
# 管理者ユーザーの作成と、ランナーの forge 側登録を行います。
# 一度だけ `aws ecs run-task` で実行してください（コマンドは outputs に出ます）。

resource "aws_ecs_task_definition" "bootstrap" {
  family             = "${var.project}-forge-bootstrap"
  network_mode       = "host"
  execution_role_arn = aws_iam_role.task_execution.arn
  task_role_arn      = aws_iam_role.task.arn

  requires_compatibilities = ["EC2"]

  volume {
    name = "forge-data"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.forge.id
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = aws_efs_access_point.forge.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = "bootstrap"
      image     = var.forge_image
      essential = true
      memory    = 512
      user      = "1000:1000"

      environment = concat(local.forge_env, [
        { name = "FORGE_ADMIN_USER", value = var.admin_username },
        { name = "FORGE_ADMIN_EMAIL", value = var.admin_email },
        { name = "RUNNER_LABELS", value = var.runner_labels },
      ])

      secrets = concat(local.forge_secrets, [
        { name = "FORGE_ADMIN_PASSWORD", valueFrom = "${local.app_secret}:admin_password::" },
        { name = "RUNNER_SECRET", valueFrom = "${local.app_secret}:runner_secret::" },
      ])

      entryPoint = ["/bin/sh", "-c"]
      command = [
        join(" ", [
          "forgejo admin user create --admin --username \"$FORGE_ADMIN_USER\"",
          "--email \"$FORGE_ADMIN_EMAIL\" --password \"$FORGE_ADMIN_PASSWORD\"",
          "--must-change-password=false || echo 'admin may already exist';",
          "forgejo forgejo-cli actions register --name ecs-runner",
          "--labels \"$RUNNER_LABELS\" --secret \"$RUNNER_SECRET\"",
          "|| echo 'runner may already be registered';",
          "echo bootstrap-done",
        ])
      ]

      mountPoints = [
        { sourceVolume = "forge-data", containerPath = "/data", readOnly = false },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.forge.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "bootstrap"
        }
      }
    },
  ])
}
