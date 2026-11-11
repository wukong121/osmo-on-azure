################################################################################
# AzureML：实验跟踪、模型注册和数据资产（system of record）
#
# - OSMO 负责调度和执行（仿真、训练、验证），AzureML 负责记录：
#   MLflow 实验跟踪、模型注册表、数据资产。AKS 上不安装 AzureML 扩展
#   （它依赖 Volcano，与 KAI Scheduler 冲突，且要求本地账号）。
# - 工作区：Basic SKU，系统分配标识，默认存储用 Identity 访问（不用 Shared Key），
#   有私有终结点；公网访问由 aml_public_network_access_enabled 控制
#   （默认开启，便于在浏览器中使用 Studio，仍受 Entra ID 和 RBAC 保护）。
# - 工作区默认存储、数据湖：关闭公网和 Shared Key，只能通过私有终结点访问。
# - 数据湖（ADLS Gen2）模拟客户的机器人数据存储，注册为 AzureML 数据存储（Identity 访问）。
# - OSMO 的工作负载标识（id-osmo）获得 AzureML Data Scientist 和两个存储的数据权限，
#   作业可以在集群内直接写 MLflow、注册模型、读写数据湖。
################################################################################

resource "azurerm_application_insights" "main" {
  name                = local.names.appi
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "other"
  tags                = local.tags
}

# ------------------------------------------------------------------------------
# 存储账号（azapi 管理面创建，原因同 storage.tf）
# ------------------------------------------------------------------------------

locals {
  private_storage_properties = {
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

  # 私有终结点：键 => 目标资源、子资源、DNS 区域、名称
  aml_private_endpoints = {
    aml_blob = {
      resource_id = azapi_resource.storage_aml.id
      subresource = "blob"
      dns_zones   = ["blob"]
      name        = local.names.pep_aml_blob
      nic_name    = local.names.nic_pep_aml_blob
    }
    aml_file = {
      resource_id = azapi_resource.storage_aml.id
      subresource = "file"
      dns_zones   = ["file"]
      name        = local.names.pep_aml_file
      nic_name    = local.names.nic_pep_aml_file
    }
    data_blob = {
      resource_id = azapi_resource.storage_data.id
      subresource = "blob"
      dns_zones   = ["blob"]
      name        = local.names.pep_data_blob
      nic_name    = local.names.nic_pep_data_blob
    }
    data_dfs = {
      resource_id = azapi_resource.storage_data.id
      subresource = "dfs"
      dns_zones   = ["dfs"]
      name        = local.names.pep_data_dfs
      nic_name    = local.names.nic_pep_data_dfs
    }
    mlw = {
      resource_id = azurerm_machine_learning_workspace.main.id
      subresource = "amlworkspace"
      dns_zones   = ["aml_api", "aml_nb"]
      name        = local.names.pep_mlw
      nic_name    = local.names.nic_pep_mlw
    }
  }
}

# AzureML 工作区默认存储（MLflow 产物、模型文件）
resource "azapi_resource" "storage_aml" {
  type      = "Microsoft.Storage/storageAccounts@2023-05-01"
  name      = local.names.storage_aml
  parent_id = azurerm_resource_group.main.id
  location  = azurerm_resource_group.main.location
  tags      = local.tags

  body = {
    kind       = "StorageV2"
    sku        = { name = "Standard_LRS" }
    properties = local.private_storage_properties
  }
}

# 数据湖：模拟客户的机器人数据存储（ADLS Gen2，开启分层命名空间）
resource "azapi_resource" "storage_data" {
  type      = "Microsoft.Storage/storageAccounts@2023-05-01"
  name      = local.names.storage_data
  parent_id = azurerm_resource_group.main.id
  location  = azurerm_resource_group.main.location
  tags      = local.tags

  body = {
    kind       = "StorageV2"
    sku        = { name = "Standard_LRS" }
    properties = merge(local.private_storage_properties, { isHnsEnabled = true })
  }

  response_export_values = ["properties.primaryEndpoints.blob", "properties.primaryEndpoints.dfs"]
}

resource "azapi_resource" "data_lake_container" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = var.data_lake_container_name
  parent_id = "${azapi_resource.storage_data.id}/blobServices/default"

  body = {
    properties = {
      publicAccess = "None"
    }
  }
}

# ------------------------------------------------------------------------------
# AzureML 工作区
# ------------------------------------------------------------------------------

resource "azurerm_machine_learning_workspace" "main" {
  name                    = local.names.mlw
  location                = azurerm_resource_group.main.location
  resource_group_name     = azurerm_resource_group.main.name
  application_insights_id = azurerm_application_insights.main.id
  key_vault_id            = azurerm_key_vault.main.id
  storage_account_id      = azapi_resource.storage_aml.id

  sku_name                      = "Basic"
  kind                          = "Default"
  public_network_access_enabled = var.aml_public_network_access_enabled
  storage_account_access_type   = "Identity"
  v1_legacy_mode_enabled        = false

  identity {
    type = "SystemAssigned"
  }

  managed_network {
    isolation_mode = "Disabled"
  }

  tags = local.tags
}

# 数据湖注册为 AzureML 数据存储（Identity 访问，不保存凭据）
resource "azurerm_machine_learning_datastore_datalake_gen2" "robotics_data" {
  name                 = replace(var.data_lake_container_name, "-", "_")
  workspace_id         = azurerm_machine_learning_workspace.main.id
  storage_container_id = azapi_resource.data_lake_container.id
  description          = "机器人数据湖（ADLS Gen2）"
}

# ------------------------------------------------------------------------------
# 私有终结点
# ------------------------------------------------------------------------------

resource "azurerm_private_endpoint" "aml" {
  for_each                      = local.aml_private_endpoints
  name                          = each.value.name
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  subnet_id                     = azurerm_subnet.private_endpoints.id
  custom_network_interface_name = each.value.nic_name
  tags                          = local.tags

  private_service_connection {
    name                           = each.value.name
    private_connection_resource_id = each.value.resource_id
    subresource_names              = [each.value.subresource]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [for z in each.value.dns_zones : azurerm_private_dns_zone.main[z].id]
  }
}

# ------------------------------------------------------------------------------
# 角色分配
# ------------------------------------------------------------------------------

locals {
  aml_role_assignments = {
    # OSMO 作业：写 MLflow、注册模型、登记数据资产
    osmo_mlw = {
      scope     = azurerm_machine_learning_workspace.main.id
      role      = "AzureML Data Scientist"
      principal = azurerm_user_assigned_identity.osmo.principal_id
    }
    # OSMO 作业：直接上传 MLflow 产物和模型文件到工作区存储
    osmo_aml_storage = {
      scope     = azapi_resource.storage_aml.id
      role      = "Storage Blob Data Contributor"
      principal = azurerm_user_assigned_identity.osmo.principal_id
    }
    # OSMO 作业：读写数据湖
    osmo_data = {
      scope     = azapi_resource.storage_data.id
      role      = "Storage Blob Data Contributor"
      principal = azurerm_user_assigned_identity.osmo.principal_id
    }
    # AzureML 工作区：浏览数据湖中的数据资产
    mlw_data = {
      scope     = azapi_resource.storage_data.id
      role      = "Storage Blob Data Reader"
      principal = azurerm_machine_learning_workspace.main.identity[0].principal_id
    }
  }
}

resource "azurerm_role_assignment" "aml" {
  for_each             = local.aml_role_assignments
  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = each.value.principal
  principal_type       = "ServicePrincipal"
}
