################################################################################
# OSMO 工作负载身份
#
# OSMO 服务、backend operator、工作流 Pod 通过 Workload Identity 使用该身份：
# - 读写 Blob（工作流数据、日志、产物）
# - 通过 Key Vault CSI 读取 PostgreSQL / Redis 凭据
################################################################################

resource "azurerm_user_assigned_identity" "osmo" {
  name                = local.names.id_osmo
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "osmo" {
  for_each = var.osmo_workload_identity_subjects

  name                      = "fic-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.osmo.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject                   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
}

resource "azurerm_role_assignment" "osmo_blob" {
  scope                = azapi_resource.storage.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.osmo.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "osmo_kv" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.osmo.principal_id
  principal_type       = "ServicePrincipal"
}
