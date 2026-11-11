################################################################################
# Azure Container Registry（仅私网）
#
# - Premium SKU（私有终结点需要 Premium），关闭公网访问
# - AKS kubelet 身份：AcrPull，工作流 Pod 可以直接使用仓库中的镜像
# - OSMO 工作负载身份（id-osmo）：AcrPush，由 OSMO 任务在 VNet 内构建并推送镜像
#   （deploy/workflows/build-image.yaml）；不启用管理员账号，不使用密码
################################################################################

resource "azurerm_container_registry" "main" {
  count = var.acr_enabled ? 1 : 0

  name                          = local.names.acr
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = false
  network_rule_bypass_option    = "AzureServices"
  zone_redundancy_enabled       = false
  tags                          = local.tags
}

resource "azurerm_private_endpoint" "acr" {
  count = var.acr_enabled ? 1 : 0

  name                          = local.names.pep_acr
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  subnet_id                     = azurerm_subnet.private_endpoints.id
  custom_network_interface_name = local.names.nic_pep_acr
  tags                          = local.tags

  private_service_connection {
    name                           = local.names.pep_acr
    private_connection_resource_id = azurerm_container_registry.main[0].id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.main["acr"].id]
  }
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  count = var.acr_enabled ? 1 : 0

  scope                = azurerm_container_registry.main[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "osmo_acr_push" {
  count = var.acr_enabled ? 1 : 0

  scope                = azurerm_container_registry.main[0].id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.osmo.principal_id
  principal_type       = "ServicePrincipal"
}
