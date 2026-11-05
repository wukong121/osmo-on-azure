output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "location" {
  value = azurerm_resource_group.main.location
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "aks_oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "aks_get_credentials_command" {
  description = "获取 kubeconfig（集群禁用了本地账号，需要 kubelogin）"
  value       = "az aks get-credentials -g ${azurerm_resource_group.main.name} -n ${azurerm_kubernetes_cluster.main.name} && kubelogin convert-kubeconfig -l azurecli"
}

output "nat_public_ip" {
  description = "集群出网 IP"
  value       = azurerm_public_ip.nat.ip_address
}

output "osmo_identity_client_id" {
  description = "OSMO 工作负载身份的 client ID（用于 ServiceAccount 注解 azure.workload.identity/client-id）"
  value       = azurerm_user_assigned_identity.osmo.client_id
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.main.fqdn
}

output "postgres_db_name" {
  value = azurerm_postgresql_flexible_server_database.osmo.name
}

output "postgres_admin_username" {
  value = var.postgres_admin_username
}

output "redis_hostname" {
  value = azurerm_managed_redis.main.hostname
}

output "redis_port" {
  value = azurerm_managed_redis.main.default_database[0].port
}

output "storage_account_name" {
  value = azapi_resource.storage.name
}

output "storage_container_name" {
  value = azapi_resource.storage_container.name
}

output "storage_blob_endpoint" {
  value = azapi_resource.storage.output.properties.primaryEndpoints.blob
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.main.vault_uri
}

output "key_vault_secret_names" {
  description = "Key Vault 中的 secret 名称"
  value = {
    postgres_password = azurerm_key_vault_secret.postgres_password.name
    redis_key         = azurerm_key_vault_secret.redis_key.name
  }
}
