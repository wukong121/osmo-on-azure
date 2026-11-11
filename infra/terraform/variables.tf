################################################################################
# 通用
################################################################################

variable "subscription_id" {
  description = "Azure 订阅 ID"
  type        = string
}

variable "location" {
  description = "Azure 区域"
  type        = string
  default     = "westus3"
}

variable "workload" {
  description = "工作负载名称，用于资源命名（小写字母数字，2-8 位）"
  type        = string
  default     = "osmo"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.workload))
    error_message = "workload 只能包含小写字母和数字，以字母开头，长度 2-8。"
  }
}

variable "environment" {
  description = "环境名称，用于资源命名（如 poc、dev、prod；小写字母数字，2-5 位）"
  type        = string
  default     = "poc"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,4}$", var.environment))
    error_message = "environment 只能包含小写字母和数字，以字母开头，长度 2-5。"
  }
}

variable "location_short" {
  description = "区域短码，用于资源命名；为空时按 naming.tf 中的映射表自动推断（westus3 → wus3）"
  type        = string
  default     = null

  validation {
    condition     = var.location_short == null || can(regex("^[a-z0-9]{2,5}$", var.location_short))
    error_message = "location_short 只能包含小写字母和数字，长度 2-5。"
  }
}

variable "unique_suffix" {
  description = "全局唯一资源（Key Vault、存储账号、PostgreSQL、Managed Redis）的名称后缀；为空时由订阅 ID 哈希生成 4 位"
  type        = string
  default     = null

  validation {
    condition     = var.unique_suffix == null || can(regex("^[a-z0-9]{3,5}$", var.unique_suffix))
    error_message = "unique_suffix 只能包含小写字母和数字，长度 3-5。"
  }
}

variable "resource_group_name" {
  description = "资源组名称；为空时使用 rg-<workload>-<environment>-<region>。Terraform 会创建该资源组"
  type        = string
  default     = null
}

variable "tags" {
  description = "附加到所有资源的标签（workload、environment、managed-by 会自动添加）"
  type        = map(string)
  default = {
    project = "osmo-on-azure"
  }
}

variable "admin_ip_cidrs" {
  description = <<-EOT
    允许访问管理面的公网 IP（CIDR 格式，如 203.0.113.10/32）。用于：
    - AKS API Server 的 authorized IP ranges
    - Key Vault 防火墙（Terraform 需要从这里写入 secret）
  EOT
  type        = list(string)

  validation {
    condition     = length(var.admin_ip_cidrs) > 0 && alltrue([for c in var.admin_ip_cidrs : can(cidrhost(c, 0))])
    error_message = "admin_ip_cidrs 至少包含一个合法的 CIDR。"
  }
}

################################################################################
# 网络
################################################################################

variable "vnet_cidr" {
  description = "VNet 地址空间"
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_cidrs" {
  description = "子网地址：aks（节点）、private_endpoints（私有终结点）、postgres（PostgreSQL 委派子网）"
  type = object({
    aks               = string
    private_endpoints = string
    postgres          = string
  })
  default = {
    aks               = "10.10.0.0/22"
    private_endpoints = "10.10.8.0/24"
    postgres          = "10.10.9.0/24"
  }
}

variable "aks_pod_cidr" {
  description = "Azure CNI Overlay 的 Pod CIDR（不占用 VNet 地址）"
  type        = string
  default     = "10.244.0.0/16"
}

variable "aks_service_cidr" {
  description = "Kubernetes Service CIDR，不能与 VNet 重叠"
  type        = string
  default     = "172.16.0.0/16"
}

variable "aks_dns_service_ip" {
  description = "CoreDNS Service IP，必须在 aks_service_cidr 内"
  type        = string
  default     = "172.16.0.10"
}

################################################################################
# AKS
################################################################################

variable "kubernetes_version" {
  description = "Kubernetes 版本；为空时使用 AKS 默认版本"
  type        = string
  default     = null
}

variable "system_node_vm_size" {
  description = "系统节点池 VM 规格（同时承载 OSMO 控制面服务，OSMO 要求 >= 8 核 / 32 GB）"
  type        = string
  default     = "Standard_D8s_v4"
}

variable "system_node_min_count" {
  description = "系统节点池最小节点数（系统池只承载 OSMO 控制面、Traefik、KAI 等平台组件；OSMO 的 CPU 作业运行在 CPU 节点池）"
  type        = number
  default     = 1
}

variable "system_node_max_count" {
  description = "系统节点池最大节点数"
  type        = number
  default     = 3
}

variable "cpu_node_pool_enabled" {
  description = "是否创建 OSMO CPU 作业节点池（npcpu）"
  type        = bool
  default     = true
}

variable "cpu_node_vm_size" {
  description = "CPU 作业节点 VM 规格（MuJoCo / Gazebo 等以 CPU 为主的仿真）"
  type        = string
  default     = "Standard_D8s_v4"
}

variable "cpu_node_min_count" {
  description = "CPU 作业节点池最小节点数。OSMO 按节点当前空闲资源校验作业，节点数为 0 时 CPU 作业会被拒绝，建议 >= 1"
  type        = number
  default     = 1
}

variable "cpu_node_max_count" {
  description = "CPU 作业节点池最大节点数"
  type        = number
  default     = 3
}

variable "acr_enabled" {
  description = "是否创建私有 Azure Container Registry（Premium + 私有终结点），用于预构建的仿真镜像"
  type        = bool
  default     = true
}

variable "gpu_node_pool_enabled" {
  description = "是否创建 GPU 节点池"
  type        = bool
  default     = true
}

variable "gpu_node_vm_size" {
  description = "GPU 节点 VM 规格（T4：Standard_NC4as_T4_v3 / NC8as / NC16as）"
  type        = string
  default     = "Standard_NC8as_T4_v3"
}

variable "gpu_node_min_count" {
  description = "GPU 节点池最小节点数（0 表示空闲时缩容到 0）"
  type        = number
  default     = 0
}

variable "gpu_node_max_count" {
  description = "GPU 节点池最大节点数（受订阅 NCASv3_T4 配额限制）"
  type        = number
  default     = 2
}

variable "gpu_node_priority" {
  description = <<-EOT
    GPU 节点池优先级：Spot 或 Regular。
    - Spot 使用 "Total Regional Low-priority vCPUs" 配额，价格约为按需的 30%，但可能被回收、容量不保证
    - Regular 使用 "Standard NCASv3_T4 Family vCPUs" 配额
  EOT
  type        = string
  default     = "Spot"

  validation {
    condition     = contains(["Spot", "Regular"], var.gpu_node_priority)
    error_message = "gpu_node_priority 只能是 Spot 或 Regular。"
  }
}

variable "gpu_node_os_sku" {
  description = "GPU 节点 OS SKU"
  type        = string
  default     = "Ubuntu2204"
}

variable "gpu_node_os_disk_size_gb" {
  description = "GPU 节点系统盘大小（仿真镜像较大，建议 >= 200 GB）"
  type        = number
  default     = 256
}

################################################################################
# 数据组件
################################################################################

variable "postgres_version" {
  description = "PostgreSQL 版本（OSMO 要求 >= 15）"
  type        = string
  default     = "16"
}

variable "postgres_sku_name" {
  description = "PostgreSQL Flexible Server SKU（OSMO 最低要求 2 核 / 4 GB）"
  type        = string
  default     = "GP_Standard_D2ds_v4"
}

variable "postgres_storage_mb" {
  description = "PostgreSQL 存储大小（MB）"
  type        = number
  default     = 32768
}

variable "postgres_admin_username" {
  description = "PostgreSQL 管理员用户名"
  type        = string
  default     = "osmoadmin"
}

variable "postgres_db_name" {
  description = "OSMO 使用的数据库名"
  type        = string
  default     = "osmo"
}

variable "redis_sku_name" {
  description = <<-EOT
    Azure Managed Redis SKU。OSMO 官方示例提示 Balanced_B0/B1/B3 在繁忙区域
    可能出现 AllocationFailed，默认选 Balanced_B5。
  EOT
  type        = string
  default     = "Balanced_B5"
}

variable "redis_high_availability_enabled" {
  description = "Managed Redis 是否启用高可用（PoC 默认关闭以节省成本）"
  type        = bool
  default     = false
}

variable "storage_container_name" {
  description = "OSMO 工作流数据、日志、产物所用的 Blob 容器"
  type        = string
  default     = "osmo"
}

variable "data_lake_container_name" {
  description = "数据湖（ADLS Gen2）中存放机器人数据的容器（文件系统）"
  type        = string
  default     = "robotics-data"
}

variable "aml_public_network_access_enabled" {
  description = "AzureML 工作区是否允许公网访问（仍需 Entra ID 认证和 RBAC）。开启后可从浏览器使用 Studio；关闭则只能从 VNet 内访问"
  type        = bool
  default     = true
}

################################################################################
# OSMO 工作负载身份
################################################################################

variable "osmo_workload_identity_subjects" {
  description = <<-EOT
    需要与 OSMO 托管身份建立联邦凭据的 Kubernetes ServiceAccount（namespace + name）。
    默认值对应 OSMO 6.3.1 chart 的默认命名：
    - service chart：global.serviceAccountName = "osmo"
    - backend-operator chart：SA 名为 "<release 名>-backend-listener/-worker"，这里假设 release 名为 osmo-operator
    - 工作流 Pod 使用 osmo-workflows 命名空间下的 osmo-workflow
    - osmo-sas-rotator：定期生成 workflow_data 的用户委托 SAS（OSMO 6.3.1 的变通方案，见 deploy/README.md）
    部署 OSMO 时如修改了 release 名或命名空间，需同步修改这里。
  EOT
  type = map(object({
    namespace       = string
    service_account = string
  }))
  default = {
    control-plane    = { namespace = "osmo", service_account = "osmo" }
    backend-listener = { namespace = "osmo-operator", service_account = "osmo-operator-backend-listener" }
    backend-worker   = { namespace = "osmo-operator", service_account = "osmo-operator-backend-worker" }
    workflow         = { namespace = "osmo-workflows", service_account = "osmo-workflow" }
    sas-rotator      = { namespace = "osmo", service_account = "osmo-sas-rotator" }
  }
}

################################################################################
# 监控
################################################################################

variable "log_analytics_retention_days" {
  description = "Log Analytics 数据保留天数"
  type        = number
  default     = 30
}
