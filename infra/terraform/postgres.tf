################################################################################
# PostgreSQL Flexible Server
#
# - VNet 注入（委派子网 + 私有 DNS），无公网访问
# - 保持 Azure 默认 require_secure_transport=on（OSMO 6.3.1 兼容，
#   见 docs/reference-repos.md 2.4 节），不沿用官方示例中关闭 TLS 的配置
################################################################################

resource "random_password" "postgres" {
  length           = 32
  special          = true
  override_special = "!#%*-_"
}

resource "azurerm_postgresql_flexible_server" "main" {
  name                          = local.names.pgsql
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  version                       = var.postgres_version
  sku_name                      = var.postgres_sku_name
  storage_mb                    = var.postgres_storage_mb
  auto_grow_enabled             = true
  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.main["postgres"].id
  public_network_access_enabled = false

  administrator_login    = var.postgres_admin_username
  administrator_password = random_password.postgres.result

  tags = local.tags

  lifecycle {
    # Azure 会自动选择可用区，避免后续 plan 出现漂移
    ignore_changes = [zone]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.main]
}

resource "azurerm_postgresql_flexible_server_database" "osmo" {
  name      = var.postgres_db_name
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

# Keycloak（浏览器登录的 OIDC 身份提供方）使用的数据库。
# 专用账号由 deploy/scripts/06-keycloak-login.sh 在集群内创建（服务器只能私网访问）。
resource "azurerm_postgresql_flexible_server_database" "keycloak" {
  name      = "keycloak"
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

# OSMO 依赖的扩展
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "HSTORE,UUID-OSSP,PG_STAT_STATEMENTS"
}
