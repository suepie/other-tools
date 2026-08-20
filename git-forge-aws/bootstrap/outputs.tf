output "state_bucket" {
  description = "tfstate を置く S3 バケット名"
  value       = aws_s3_bucket.tfstate.id
}

output "state_kms_key_arn" {
  description = "tfstate 暗号化に使う KMS キー"
  value       = aws_kms_key.tfstate.arn
}

output "backend_config" {
  description = <<-EOT
    バックエンド設定の中身。
    apply 時に ecs/backend.hcl へ自動で書き出されるので、通常は使いません
    （手で再生成したいときの控えとして残しています）。
  EOT
  value       = local.backend_config
}

output "backend_config_path" {
  description = "自動生成された backend.hcl のパス"
  value       = local_file.backend_config.filename
}
