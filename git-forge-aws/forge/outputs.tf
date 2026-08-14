output "forge_url" {
  description = "Forge の URL（allowed_cidrs からのみアクセス可）"
  value       = "https://${var.domain_name}/"
}

output "instance_id" {
  description = "Forge インスタンスの ID"
  value       = aws_instance.forge.id
}

output "connect_command" {
  description = "インスタンスに入るコマンド（SSH 鍵は不要）"
  value       = "aws ssm start-session --target ${aws_instance.forge.id} --region ${var.region}"
}

output "admin_password_command" {
  description = "初期管理者パスワードを取り出すコマンド"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.admin.name} --region ${var.region} --query SecretString --output text"
}

output "bootstrap_log_command" {
  description = "初期化がうまくいかないときにログを見るコマンド"
  value       = "aws ssm start-session --target ${aws_instance.forge.id} --region ${var.region} --document-name AWS-StartInteractiveCommand --parameters command='sudo tail -n 200 /var/log/forge-bootstrap.log'"
}

output "kms_key_arn" {
  description = "このプロジェクト専用の CMK（EBS / Secrets の暗号化）"
  value       = aws_kms_key.forge.arn
}

output "data_volume_id" {
  description = "リポジトリが載っている EBS ボリューム（スナップショット取得対象）"
  value       = aws_ebs_volume.data.id
}
