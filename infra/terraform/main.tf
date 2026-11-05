data "azurerm_client_config" "current" {}

locals {
  tags = merge(
    {
      workload    = var.workload
      environment = var.environment
      managed-by  = "terraform"
    },
    var.tags,
  )
}

resource "azurerm_resource_group" "main" {
  name     = local.names.resource_group
  location = var.location
  tags     = local.tags
}
