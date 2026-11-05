################################################################################
# Azure Managed Redis（OSMO 要求 Redis 7+）
#
# - 关闭公网访问，仅通过私有终结点访问
# - clustering_policy 必须为 EnterpriseCluster：OSMO 使用非集群模式客户端，
#   OSSCluster 会返回 MOVED 导致提交失败；该属性创建后不可修改
# - 必须启用 access key 认证，否则 Terraform 拿不到密钥
################################################################################

resource "azurerm_managed_redis" "main" {
  name                      = local.names.amr
  location                  = azurerm_resource_group.main.location
  resource_group_name       = azurerm_resource_group.main.name
  sku_name                  = var.redis_sku_name
  high_availability_enabled = var.redis_high_availability_enabled
  public_network_access     = "Disabled"

  default_database {
    client_protocol                    = "Encrypted"
    clustering_policy                  = "EnterpriseCluster"
    eviction_policy                    = "VolatileLRU"
    access_keys_authentication_enabled = true
  }

  tags = local.tags

  timeouts {
    create = "90m"
    update = "90m"
    delete = "90m"
  }
}

resource "azurerm_private_endpoint" "redis" {
  name                          = local.names.pep_amr
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  subnet_id                     = azurerm_subnet.private_endpoints.id
  custom_network_interface_name = local.names.nic_pep_amr
  tags                          = local.tags

  private_service_connection {
    name                           = local.names.pep_amr
    private_connection_resource_id = azurerm_managed_redis.main.id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.main["redis"].id]
  }
}
