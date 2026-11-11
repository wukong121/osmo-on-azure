################################################################################
# 外部计算后端（多云 / 本地）
#
# 模拟客户在其他云或本地机房的算力，作为 OSMO 的额外计算后端接入：
# - 一台 k3s 虚拟机（独立资源组、独立 VNet，不与 PoC 网络互联，只能经公网访问 Azure）
#   代表“其他云厂商的 Kubernetes 集群”；本地机房的集群（external_extra_cidrs）不由
#   Terraform 创建，只登记其出口 IP 和 OIDC 签发方
# - ACR 在保留私有终结点的同时按 IP 白名单开放公网，只允许外部集群的出口 IP
# - 存储账号（OSMO Blob、AzureML 存储、数据湖）保持仅私网；外部集群经公网入口上的 SNI 透传网关
#   访问（TLS 端到端到存储，网关做 IP 白名单），认证仍是短时效 SAS / Entra ID，不使用共享密钥
# - 外部集群的服务账号令牌签发方（OIDC issuer）通过联邦凭据信任 OSMO 托管身份，
#   外部集群的工作流 Pod 也能免密钥访问 AzureML 和数据湖（对应阿里云 ACK 的 RRSA 等机制）
#
# external_backends_enabled = false 时不创建任何资源，数据组件保持仅私网。
################################################################################

locals {
  ext_enabled = var.external_backends_enabled
  ext_names = {
    resource_group = "rg-${var.workload}-${var.environment}-ext"
    vnet           = "vnet-${var.workload}-${var.environment}-ext"
    nsg            = "nsg-${var.workload}-${var.environment}-ext"
    pip            = "pip-${var.workload}-${var.environment}-ext-k3s"
    nic            = "nic-${var.workload}-${var.environment}-ext-k3s"
    vm             = "vm-${var.workload}-${var.environment}-ext-k3s"
  }

  # 允许访问数据组件公网端点的外部出口 IP（外部 k3s 虚拟机 + 手工登记的本地机房等）
  ext_cidrs = local.ext_enabled ? concat(
    ["${azurerm_public_ip.ext[0].ip_address}/32"],
    var.external_extra_cidrs,
  ) : []
  # 存储账号保持仅私网：订阅所在管理组有策略（Modify）强制关闭存储账号的公网访问，
  # IP 白名单不会生效。外部集群经公网入口上的 SNI 透传网关访问存储（deploy/manifests/storage-gateway.yaml）
  storage_network_properties = {
    publicNetworkAccess = "Disabled"
    networkAcls = {
      defaultAction = "Deny"
      bypass        = "AzureServices"
    }
  }
}

resource "azurerm_resource_group" "ext" {
  count    = local.ext_enabled ? 1 : 0
  name     = local.ext_names.resource_group
  location = var.external_location
  tags     = merge(local.tags, { role = "external-compute-simulation" })
}

resource "azurerm_virtual_network" "ext" {
  count               = local.ext_enabled ? 1 : 0
  name                = local.ext_names.vnet
  location            = azurerm_resource_group.ext[0].location
  resource_group_name = azurerm_resource_group.ext[0].name
  address_space       = ["10.30.0.0/16"]
  tags                = azurerm_resource_group.ext[0].tags
}

resource "azurerm_subnet" "ext" {
  count                = local.ext_enabled ? 1 : 0
  name                 = "snet-k3s"
  resource_group_name  = azurerm_resource_group.ext[0].name
  virtual_network_name = azurerm_virtual_network.ext[0].name
  address_prefixes     = ["10.30.0.0/24"]
}

# 不开放任何入站端口：OSMO backend operator 只需要出站连接；运维通过云厂商的管理面通道执行命令
# （这里是 az vm run-command，对应其他云的云助手等），而不是 SSH。部分订阅（如 MCAPS）的策略也会
# 自动删除对公网开放管理端口的规则。
resource "azurerm_network_security_group" "ext" {
  count               = local.ext_enabled ? 1 : 0
  name                = local.ext_names.nsg
  location            = azurerm_resource_group.ext[0].location
  resource_group_name = azurerm_resource_group.ext[0].name
  tags                = azurerm_resource_group.ext[0].tags
}

resource "azurerm_subnet_network_security_group_association" "ext" {
  count                     = local.ext_enabled ? 1 : 0
  subnet_id                 = azurerm_subnet.ext[0].id
  network_security_group_id = azurerm_network_security_group.ext[0].id
}

resource "azurerm_public_ip" "ext" {
  count               = local.ext_enabled ? 1 : 0
  name                = local.ext_names.pip
  location            = azurerm_resource_group.ext[0].location
  resource_group_name = azurerm_resource_group.ext[0].name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = azurerm_resource_group.ext[0].tags

  lifecycle {
    # 部分订阅（如 MCAPS）的策略会自动添加 ip_tags（FirstPartyUsage），否则每次都会重建公网 IP
    ignore_changes = [ip_tags]
  }
}

resource "azurerm_network_interface" "ext" {
  count               = local.ext_enabled ? 1 : 0
  name                = local.ext_names.nic
  location            = azurerm_resource_group.ext[0].location
  resource_group_name = azurerm_resource_group.ext[0].name
  tags                = azurerm_resource_group.ext[0].tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.ext[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.ext[0].id
  }
}

resource "azurerm_linux_virtual_machine" "ext" {
  count                 = local.ext_enabled ? 1 : 0
  name                  = local.ext_names.vm
  location              = azurerm_resource_group.ext[0].location
  resource_group_name   = azurerm_resource_group.ext[0].name
  size                  = var.external_vm_size
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.ext[0].id]
  tags                  = azurerm_resource_group.ext[0].tags

  admin_ssh_key {
    username   = "azureuser"
    public_key = file(pathexpand(var.external_ssh_public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 256
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  lifecycle {
    # Set by subscription policy (patch orchestration)
    ignore_changes = [bypass_platform_safety_checks_on_user_schedule_enabled]
  }
}

# 外部集群的 OIDC 签发方 → OSMO 托管身份（工作流 Pod 的服务账号）
resource "azurerm_federated_identity_credential" "ext" {
  for_each = local.ext_enabled ? var.external_oidc_issuers : {}

  name                      = "fic-ext-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.osmo.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = each.value
  subject                   = "system:serviceaccount:${var.osmo_workload_identity_subjects["workflow"].namespace}:${var.osmo_workload_identity_subjects["workflow"].service_account}"
}
