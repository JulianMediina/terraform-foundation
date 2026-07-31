output "tfstate_buckets" {
  description = "Nombre del bucket de estado por ambiente."
  value       = { for env, bucket in aws_s3_bucket.tfstate : env => bucket.id }
}

output "tflock_tables" {
  description = "Nombre de la tabla de lock por ambiente."
  value       = { for env, table in aws_dynamodb_table.tflock : env => table.id }
}

output "site_kms_key_arns" {
  description = "ARN de la llave KMS de cifrado del bucket de sitio, por ambiente."
  value       = { for env, key in aws_kms_key.site : env => key.arn }
}

output "gha_role_arns" {
  description = "ARN del rol OIDC de GitHub Actions, por ambiente."
  value       = local.gha_role_arns
}

output "oidc_provider_arn" {
  description = "ARN del proveedor OIDC de GitHub, compartido por los tres ambientes."
  value       = module.gha_role_provider.oidc_provider_arn
}
