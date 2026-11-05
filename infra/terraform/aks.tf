################################################################################
# AKS 控制面身份
#
# 自带 VNet + NAT Gateway 时，控制面身份需要在建集群之前拥有子网的
# Network Contributor 权限，因此使用用户分配身份并预先授权。
################################################################################

resource "azurerm_user_assigned_identity" "aks" {
  name                = local.names.id_aks
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "aks_network" {
  scope                = azurerm_virtual_network.main.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
  principal_type       = "ServicePrincipal"
}

################################################################################
# AKS 集群
#
# - API Server：公网 + authorized IP ranges（admin_ip_cidrs + NAT 出口 IP）
# - 认证：Entra ID + Azure RBAC，禁用本地账号
# - 网络：Azure CNI Overlay + Cilium，出网走 NAT Gateway
# - 启用 OIDC Issuer / Workload Identity / Key Vault CSI
################################################################################

resource "azurerm_kubernetes_cluster" "main" {
  name                = local.names.aks
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = local.names.aks_dns_prefix
  kubernetes_version  = var.kubernetes_version
  node_resource_group = local.names.aks_node_rg
  sku_tier            = "Free"

  oidc_issuer_enabled       = true
  workload_identity_enabled = true
  local_account_disabled    = true

  api_server_access_profile {
    authorized_ip_ranges = concat(var.admin_ip_cidrs, ["${azurerm_public_ip.nat.ip_address}/32"])
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  default_node_pool {
    name                        = local.names.np_system
    temporary_name_for_rotation = local.names.np_system_tmp
    vm_size                     = var.system_node_vm_size
    auto_scaling_enabled        = true
    min_count                   = var.system_node_min_count
    max_count                   = var.system_node_max_count
    vnet_subnet_id              = azurerm_subnet.aks.id
    os_disk_size_gb             = 128
    max_pods                    = 110

    upgrade_settings {
      max_surge = "10%"
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = var.aks_pod_cidr
    service_cidr        = var.aks_service_cidr
    dns_service_ip      = var.aks_dns_service_ip
    load_balancer_sku   = "standard"
    outbound_type       = "userAssignedNATGateway"
  }

  # 不启用 Node Auto Provisioning，节点池由本文件显式定义
  node_provisioning_profile {
    mode = "Manual"
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.main.id
    msi_auth_for_monitoring_enabled = true
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count,
    ]
  }

  depends_on = [
    azurerm_role_assignment.aks_network,
    azurerm_subnet_nat_gateway_association.aks,
  ]
}

# 部署者获得集群管理员权限（集群禁用了本地账号，需通过 Entra ID 访问）
resource "azurerm_role_assignment" "deployer_aks_admin" {
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

################################################################################
# GPU 节点池（T4）
#
# - gpu_driver = "None"：不使用 AKS 自带驱动，由 GPU Operator 安装 595 分支驱动
#   （Isaac Lab 3.0 要求 >= 595.58.03，见 docs/t4-feasibility.md）
# - 使用 NVIDIA 标准 taint，GPU Operator / KAI 默认容忍
# - Regular 优先级，避免 Spot 回收打断作业
################################################################################

resource "azurerm_kubernetes_cluster_node_pool" "gpu" {
  count = var.gpu_node_pool_enabled ? 1 : 0

  name                  = local.names.np_gpu
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.gpu_node_vm_size
  os_sku                = var.gpu_node_os_sku
  os_disk_size_gb       = var.gpu_node_os_disk_size_gb
  vnet_subnet_id        = azurerm_subnet.aks.id
  max_pods              = 110

  auto_scaling_enabled = true
  min_count            = var.gpu_node_min_count
  max_count            = var.gpu_node_max_count

  gpu_driver = "None"
  priority   = "Regular"

  node_taints = ["nvidia.com/gpu=present:NoSchedule"]
  node_labels = {
    "nvidia.com/gpu" = "present"
    "osmo/node-type" = "gpu"
    "osmo/gpu-model" = local.names.np_gpu
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}
