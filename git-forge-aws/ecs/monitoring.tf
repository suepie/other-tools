#
# アラーム。
#
# forge のタスクは OOM などで再起動すると、新しいタスクが healthy になるまで
# 1〜3 分ほど 503 を返します。ECS は自動で復旧させるため、通知がないと気付けません。
#
# ★見るべきメトリクスは HTTPCode_ELB_5XX_Count です。
#   UnHealthyHostCount では検知できません。タスクが落ちるとターゲットは
#   「unhealthy になる」のではなく「登録解除される」ため、障害中も
#   UnHealthyHostCount は 0、HealthyHostCount は 1 のままになります。
#

locals {
  alarm_email = var.alarm_email != "" ? var.alarm_email : var.admin_email
}

resource "aws_sns_topic" "alarms" {
  name              = "${local.name_prefix}-alarms"
  kms_master_key_id = aws_kms_key.forge.arn

  tags = { Name = "${local.name_prefix}-alarms" }
}

# 確認メールが届きます。Confirm subscription を押すまで通知は飛びません。
# pending_confirmation のままになるのは Terraform では検知できないので、
# apply 後にメールを確認してください。
resource "aws_sns_topic_subscription" "alarms_email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = local.alarm_email
}

# ALB 自身が返した 5XX。登録先がゼロ（= forge が落ちている）だとここが上がります。
# 1 分間に 5 件を 1 回でも超えたら通知。再起動中はこれを大きく超える件数が出るので
# 確実に拾えますが、単発のエラーでは鳴りません。
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name        = "${local.name_prefix}-alb-5xx"
  alarm_description = "ALB が 5XX を返しています（forge のタスクが落ちている可能性）"

  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    LoadBalancer = aws_lb.forge.arn_suffix
  }

  # 障害中はデータポイント自体が欠ける場合があるため、欠損は「正常」扱いにします。
  # （欠損を breaching にすると平常時も鳴り続けます）
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = { Name = "${local.name_prefix}-alb-5xx" }
}

# ECS インスタンスの CPU。
#
# forge 内部のビジーループ（例: bleve での日本語検索の暴走）で vCPU が埋まると、
# git 操作がタイムアウトして Actions のジョブが軒並み失敗します。
# タスクは落ちないので 5XX アラームでは拾えず、こちらで検知します。
#
# ★Container Insights（container_insights = true）が前提のメトリクスなので、
#   無効にした場合はこのアラームも作りません。
#
# Managed Instances はインスタンスを入れ替えるため InstanceId では追えません。
# ECS サービス単位の CpuUtilized（Container Insights）を見ます。
# forge のタスクに CPU 上限は設定していないので、ホストの全 vCPU 分まで上がります。
resource "aws_cloudwatch_metric_alarm" "forge_cpu" {
  count = var.container_insights ? 1 : 0

  alarm_name        = "${local.name_prefix}-forge-cpu"
  alarm_description = "forge が CPU を使い切っています（内部のビジーループの可能性）"

  namespace   = "ECS/ContainerInsights"
  metric_name = "CpuUtilized"
  statistic   = "Average"
  period      = 300

  # 5 分平均が 10 回連続（約 50 分）で閾値超え。
  # 一時的な clone / index のスパイクでは鳴らず、張り付きだけを拾います。
  evaluation_periods  = 10
  datapoints_to_alarm = 10

  # vCPU 数 × 1024 の 85%。instance_vcpu_min を変えたら自動で追従します。
  threshold           = floor(var.instance_vcpu_min * 1024 * 0.85)
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    ClusterName = aws_ecs_cluster.this.name
    ServiceName = aws_ecs_service.forge.name
  }

  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = { Name = "${local.name_prefix}-forge-cpu" }
}

# count を付ける前に作成済みの環境で、作り直しにならないようにするため。
moved {
  from = aws_cloudwatch_metric_alarm.forge_cpu
  to   = aws_cloudwatch_metric_alarm.forge_cpu[0]
}
