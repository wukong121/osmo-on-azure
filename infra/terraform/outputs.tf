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

output "postgres_keycloak_db_name" {
  value = azurerm_postgresql_flexible_server_database.keycloak.name
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

output "postgres_admin_password" {
  description = "PostgreSQL 管理员密码（敏感，部署脚本读取后写入 K8s Secret）"
  value       = random_password.postgres.result
  sensitive   = true
}

output "redis_primary_key" {
  description = "Managed Redis 访问密钥（敏感，部署脚本读取后写入 K8s Secret）"
  value       = azurerm_managed_redis.main.default_database[0].primary_access_key
  sensitive   = true
}

output "ingress_public_ip" {
  description = "Traefik 公网入口的固定 IP（DNS A 记录指向它）"
  value       = azurerm_public_ip.ingress.ip_address
}

output "ingress_public_ip_name" {
  value = azurerm_public_ip.ingress.name
}

################################################################################
# AzureML 与数据湖
################################################################################

output "aml_workspace_name" {
  value = azurerm_machine_learning_workspace.main.name
}

output "aml_workspace_id" {
  value = azurerm_machine_learning_workspace.main.id
}

output "aml_storage_account_name" {
  value = azapi_resource.storage_aml.name
}

output "data_lake_account_name" {
  value = azapi_resource.storage_data.name
}

output "data_lake_container_name" {
  value = azapi_resource.data_lake_container.name
}

output "data_lake_datastore_name" {
  value = azurerm_machine_learning_datastore_datalake_gen2.robotics_data.name
}
