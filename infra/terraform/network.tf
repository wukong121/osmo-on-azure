################################################################################
# VNet 与子网
#
# - snet-aks：AKS 节点（Azure CNI Overlay，Pod IP 不占用 VNet 地址）
# - snet-pe：私有终结点（Redis / Blob / Key Vault）
# - snet-postgres：PostgreSQL Flexible Server 委派子网（VNet 注入）
################################################################################

resource "azurerm_virtual_network" "main" {
  name                = local.names.vnet
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "aks" {
  name                 = local.names.snet_aks
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_cidrs.aks]
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = local.names.snet_pep
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_cidrs.private_endpoints]
}

resource "azurerm_subnet" "postgres" {
  name                 = local.names.snet_pgsql
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_cidrs.postgres]

  delegation {
    name = "postgres-flexible"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

################################################################################
# NAT Gateway：AKS 节点出网（拉取 nvcr.io 镜像等）
################################################################################

resource "azurerm_public_ip" "nat" {
  name                = local.names.pip_nat
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags

  lifecycle {
    # 部分订阅（如 MCAPS）的策略会自动添加 ip_tags（FirstPartyUsage），
    # ip_tags 变更会强制重建公网 IP，导致出口 IP 变化
    ignore_changes = [ip_tags]
  }
}

resource "azurerm_nat_gateway" "main" {
  name                = local.names.nat_gateway
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  nat_gateway_id       = azurerm_nat_gateway.main.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "aks" {
  subnet_id      = azurerm_subnet.aks.id
  nat_gateway_id = azurerm_nat_gateway.main.id
}

################################################################################
# 私有 DNS 区域（链接到 VNet）
################################################################################

locals {
  private_dns_zones = {
    blob     = "privatelink.blob.core.windows.net"
    vault    = "privatelink.vaultcore.azure.net"
    redis    = "privatelink.redis.azure.net"
    postgres = local.names.pgsql_dns_zone
  }
}

resource "azurerm_private_dns_zone" "main" {
  for_each            = local.private_dns_zones
  name                = each.value
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "main" {
  for_each             = local.private_dns_zones
  name                 = local.names.dns_vnet_link
  private_dns_zone_id  = azurerm_private_dns_zone.main[each.key].id
  virtual_network_id   = azurerm_virtual_network.main.id
  registration_enabled = false
  tags                 = local.tags
}

################################################################################
# 公网入口（Traefik）
#
# - 固定公网 IP：由 Terraform 管理，Traefik 的 LoadBalancer Service 通过注解使用它，
#   重装 Traefik 不会改变 IP（DNS 记录保持有效）
# - snet-aks 的 NSG：只对入口 IP 放行来自 Internet 的 80/443。
#   部分订阅（如 MCAPS）的策略会给子网自动挂一个默认拒绝入站的 NSG，
#   这里用自管的 NSG 替换它，在没有该策略的订阅中同样适用
################################################################################

resource "azurerm_public_ip" "ingress" {
  name                = local.names.pip_ingress
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags

  lifecycle {
    ignore_changes = [ip_tags]
  }
}

# AKS 使用节点资源组之外的公网 IP 时，控制面身份需要该资源组的 Network Contributor
resource "azurerm_role_assignment" "aks_ingress_pip" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_network_security_group" "aks" {
  name                = local.names.nsg_aks
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  security_rule {
    name                       = "allow-internet-to-ingress-http-https"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "Internet"
    source_port_range          = "*"
    destination_address_prefix = azurerm_public_ip.ingress.ip_address
    destination_port_ranges    = ["80", "443"]
  }
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}
