################################################################################
# Blob 存储：OSMO 工作流数据、日志、产物
#
# - 禁用 Shared Key，只允许 Entra ID（Workload Identity）访问
# - 关闭公网访问，仅通过私有终结点访问
# - 使用 azapi 走管理面创建账号和容器：关闭公网后部署机无法访问数据面，
#   azurerm 的存储资源在读取时可能调用数据面接口
################################################################################

resource "azapi_resource" "storage" {
  type      = "Microsoft.Storage/storageAccounts@2023-05-01"
  name      = local.names.storage_account
  parent_id = azurerm_resource_group.main.id
  location  = azurerm_resource_group.main.location
  tags      = local.tags

  body = {
    kind = "StorageV2"
    sku = {
      name = "Standard_LRS"
    }
    properties = {
      accessTier                   = "Hot"
      allowBlobPublicAccess        = false
      allowSharedKeyAccess         = false
      defaultToOAuthAuthentication = true
      minimumTlsVersion            = "TLS1_2"
      supportsHttpsTrafficOnly     = true
      # 默认仅私网；启用外部计算后端后按 IP 白名单开放（见 external.tf）
      publicNetworkAccess = local.storage_network_properties.publicNetworkAccess
      networkAcls         = local.storage_network_properties.networkAcls
    }
  }

  response_export_values = ["properties.primaryEndpoints.blob"]
}

resource "azapi_resource" "storage_container" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = var.storage_container_name
  parent_id = "${azapi_resource.storage.id}/blobServices/default"

  body = {
    properties = {
      publicAccess = "None"
    }
  }
}

resource "azurerm_private_endpoint" "blob" {
  name                          = local.names.pep_blob
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  subnet_id                     = azurerm_subnet.private_endpoints.id
  custom_network_interface_name = local.names.nic_pep_blob
  tags                          = local.tags

  private_service_connection {
    name                           = local.names.pep_blob
    private_connection_resource_id = azapi_resource.storage.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.main["blob"].id]
  }
}
