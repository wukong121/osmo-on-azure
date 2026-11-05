################################################################################
# Key Vault（仅私网）
#
# - RBAC 模式，公网访问关闭，仅通过私有终结点访问
# - 部分订阅（如 MCAPS）有策略强制关闭 Key Vault 公网访问，因此 Terraform 不从
#   VNet 外写入 secret；PostgreSQL 密码和 Redis 密钥通过敏感输出交给部署脚本
#   （见 outputs.tf）。Key Vault 预留给后续 Key Vault CSI / 集群内密钥管理使用。
################################################################################

resource "azurerm_key_vault" "main" {
  name                       = local.names.key_vault
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7

  public_network_access_enabled = false
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }

  tags = local.tags
}

# 部署者可从 VNet 内（跳板机）管理 secret
resource "azurerm_role_assignment" "deployer_kv_secrets_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_private_endpoint" "key_vault" {
  name                          = local.names.pep_kv
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  subnet_id                     = azurerm_subnet.private_endpoints.id
  custom_network_interface_name = local.names.nic_pep_kv
  tags                          = local.tags

  private_service_connection {
    name                           = local.names.pep_kv
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.main["vault"].id]
  }
}
