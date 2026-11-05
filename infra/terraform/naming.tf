################################################################################
# 资源命名
#
# 遵循 Cloud Adoption Framework（CAF）的资源缩写和命名规范：
#   <缩写>-<workload>-<environment>-<region>[-<用途>][-<唯一后缀>]
# 例：aks-osmo-poc-wus3、pep-osmo-poc-wus3-kv、kv-osmo-poc-wus3-1a2b
#
# - 缩写：https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations
# - 长度与字符限制：https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules
# - 全局唯一的资源（Key Vault、存储账号、PostgreSQL、Managed Redis）追加 4 位唯一后缀。
#   后缀由订阅 ID 和基础名称哈希得到，部署前即可确定，重复部署保持不变。
################################################################################

locals {
  # 区域短码（CAF 常用写法），未列出的区域需通过 var.location_short 指定
  location_short_map = {
    westus3        = "wus3"
    westus2        = "wus2"
    westus         = "wus"
    eastus         = "eus"
    eastus2        = "eus2"
    centralus      = "cus"
    southcentralus = "scus"
    southeastasia  = "sea"
    eastasia       = "ea"
    japaneast      = "jpe"
    japanwest      = "jpw"
    koreacentral   = "krc"
    westeurope     = "weu"
    northeurope    = "neu"
  }
  location_short = coalesce(var.location_short, lookup(local.location_short_map, var.location, "unknown"))

  # 基础名称，如 osmo-poc-wus3
  base_name = "${var.workload}-${var.environment}-${local.location_short}"
  # 去掉连字符的版本，供只允许字母数字的资源使用（存储账号）
  base_name_compact = replace(local.base_name, "-", "")

  unique_suffix = coalesce(var.unique_suffix, substr(sha1("${var.subscription_id}/${local.base_name}"), 0, 4))

  names = {
    # 资源组
    resource_group = coalesce(var.resource_group_name, "rg-${local.base_name}")
    aks_node_rg    = "rg-${local.base_name}-aksnodes"

    # 网络
    vnet           = "vnet-${local.base_name}"
    snet_aks       = "snet-aks"
    snet_pep       = "snet-pep"
    snet_pgsql     = "snet-pgsql"
    pip_nat        = "pip-${local.base_name}-ng"
    nat_gateway    = "ng-${local.base_name}"
    dns_vnet_link  = "vnetlink-${local.base_name}"
    pgsql_dns_zone = "${local.base_name}.private.postgres.database.azure.com"

    # AKS（节点池名称：Linux 1-12 位小写字母数字，不能以数字开头）
    aks            = "aks-${local.base_name}"
    aks_dns_prefix = "aks-${local.base_name}"
    np_system      = "npsystem"
    np_system_tmp  = "npsystmp"
    np_gpu         = "npgput4"

    # 身份
    id_aks  = "id-${local.base_name}-aks"
    id_osmo = "id-${local.base_name}-osmo"

    # 数据组件（全局唯一）
    key_vault       = "kv-${local.base_name}-${local.unique_suffix}"
    storage_account = "st${local.base_name_compact}${local.unique_suffix}"
    pgsql           = "pgsql-${local.base_name}-${local.unique_suffix}"
    amr             = "amr-${local.base_name}-${local.unique_suffix}"

    # 私有终结点（pep）及其网卡（nic）
    pep_kv       = "pep-${local.base_name}-kv"
    pep_blob     = "pep-${local.base_name}-blob"
    pep_amr      = "pep-${local.base_name}-amr"
    nic_pep_kv   = "nic-pep-${local.base_name}-kv"
    nic_pep_blob = "nic-pep-${local.base_name}-blob"
    nic_pep_amr  = "nic-pep-${local.base_name}-amr"

    # 监控
    log_analytics          = "log-${local.base_name}"
    dcr_container_insights = "dcr-${local.base_name}-ci"
  }
}

# 在 plan 阶段校验命名长度与字符限制，避免 apply 到一半才失败
resource "terraform_data" "naming_validation" {
  input = local.names

  lifecycle {
    precondition {
      condition     = local.location_short != "unknown"
      error_message = "区域 ${var.location} 没有内置短码，请通过 location_short 指定（如 wus3）。"
    }
    precondition {
      condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", local.names.key_vault)) && !strcontains(local.names.key_vault, "--")
      error_message = "Key Vault 名称 ${local.names.key_vault} 不合法：3-24 位字母数字和连字符，字母开头，不能以连字符结尾或包含连续连字符。请缩短 workload / environment。"
    }
    precondition {
      condition     = can(regex("^[a-z0-9]{3,24}$", local.names.storage_account))
      error_message = "存储账号名称 ${local.names.storage_account} 不合法：3-24 位小写字母数字。请缩短 workload / environment。"
    }
    precondition {
      condition     = length(local.names.pgsql) <= 63 && length(local.names.amr) <= 63
      error_message = "PostgreSQL / Managed Redis 名称超过 63 个字符。"
    }
  }
}
