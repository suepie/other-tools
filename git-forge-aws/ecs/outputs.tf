output "forge_url" {
  description = "Forgejo の URL（allowed_cidrs からのみアクセス可）"
  value       = local.forge_root_url
}

output "cloudfront_distribution_id" {
  description = "CloudFront ディストリビューション ID"
  value       = aws_cloudfront_distribution.forge.id
}

output "waf_ip_set_name" {
  description = "許可 IP を管理している WAF IP セット（us-east-1）"
  value       = aws_wafv2_ip_set.allowed.name
}

output "origin_read_timeout" {
  description = "オリジン応答タイムアウト（無通信が続いた時間の上限）"
  value       = "${var.origin_read_timeout}s"
}

output "bootstrap_command" {
  description = <<-EOT
    初期セットアップ（管理者作成 + ランナー登録）を一度だけ実行するコマンド。
    apply 後、forge サービスが安定してから実行してください。
  EOT
  value = join(" ", [
    "aws ecs run-task",
    "--cluster ${aws_ecs_cluster.this.name}",
    "--task-definition ${aws_ecs_task_definition.bootstrap.family}",
    "--capacity-provider-strategy capacityProvider=${aws_ecs_capacity_provider.managed.name},weight=1",
    "--region ${var.region}",
  ])
}

output "admin_credentials_command" {
  description = "初期管理者のログイン情報を取り出すコマンド"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.admin.name} --region ${var.region} --query SecretString --output text"
}

output "exec_command" {
  description = "Forgejo コンテナに入るコマンド（SSH 鍵は不要）"
  value = join(" ", [
    "aws ecs execute-command",
    "--cluster ${aws_ecs_cluster.this.name}",
    "--task $(aws ecs list-tasks --cluster ${aws_ecs_cluster.this.name} --service-name ${aws_ecs_service.forge.name} --region ${var.region} --query 'taskArns[0]' --output text)",
    "--container forgejo --interactive --command /bin/bash",
    "--region ${var.region}",
  ])
}

output "log_group" {
  description = "forge / runner / bootstrap のログが出る CloudWatch Logs グループ"
  value       = aws_cloudwatch_log_group.forge.name
}

output "efs_id" {
  description = "ベア Git リポジトリを置いている EFS"
  value       = aws_efs_file_system.forge.id
}

output "s3_bucket" {
  description = "LFS / 添付 / Packages / Actions 成果物の置き場"
  value       = aws_s3_bucket.objects.id
}

output "db_endpoint" {
  description = "RDS のエンドポイント"
  value       = aws_db_instance.forge.address
}

output "kms_key_arn" {
  description = "このプロジェクト専用の CMK"
  value       = aws_kms_key.forge.arn
}
