output "state_bucket" {
  description = "tfstate を置く S3 バケット名"
  value       = aws_s3_bucket.tfstate.id
}

output "state_kms_key_arn" {
  description = "tfstate 暗号化に使う KMS キー"
  value       = aws_kms_key.tfstate.arn
}

output "backend_config" {
  description = "forge/backend.hcl にそのまま貼れるバックエンド設定"
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.tfstate.id}"
    key          = "forge/terraform.tfstate"
    region       = "${var.region}"
    encrypt      = true
    kms_key_id   = "${aws_kms_key.tfstate.arn}"
    use_lockfile = true
  EOT
}
