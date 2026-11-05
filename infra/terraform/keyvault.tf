################################################################################
# Key Vault：存放 PostgreSQL 密码、Redis 访问密钥
#
# - RBAC 模式；AKS 通过 Key Vault CSI + Workload Identity 读取
# - 私有终结点供集群内访问；公网入口仅对 admin_ip_cidrs 开放，
#   因为 Terraform 写入 secret 属于数据面操作，需要从部署机访问。
#   部署完成后如需完全关闭公网，可将 public_network_access_enabled 改为 false。
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

  public_network_access_enabled = true
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    # Key Vault 会把 /32 规范化为单个 IP，这里提前去掉以避免反复 diff
    ip_rules = [for c in var.admin_ip_cidrs : trimsuffix(c, "/32")]
  }

  tags = local.tags
}

resource "azurerm_role_assignment" "deployer_kv_secrets_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# 等待 RBAC 生效，避免首次写入 secret 时 403
resource "time_sleep" "kv_rbac_propagation" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.deployer_kv_secrets_officer]
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

resource "azurerm_key_vault_secret" "postgres_password" {
  name         = "postgres-admin-password"
  value        = random_password.postgres.result
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [time_sleep.kv_rbac_propagation]
}

resource "azurerm_key_vault_secret" "redis_key" {
  name         = "redis-primary-key"
  value        = azurerm_managed_redis.main.default_database[0].primary_access_key
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [time_sleep.kv_rbac_propagation]
}
