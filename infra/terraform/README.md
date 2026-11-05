# OSMO on Azure: infrastructure (Terraform)

English | [简体中文](README.zh-CN.md)

This module provisions the Azure infrastructure for PoC phase 1. OSMO 6.3.1 runs on top of it but is not deployed here; it is installed with Helm in a separate step.

## Architecture

![OSMO on Azure architecture](../../docs/images/azure-architecture.png)

_Edges: green = private (VNet / Private Link) · orange dashed = public endpoint restricted to admin IPs · grey = outbound via NAT · blue dotted = identity / monitoring._

| Component | Access | Notes |
|---|---|---|
| AKS API server | Public endpoint with authorized IP ranges | Local accounts are disabled; sign-in uses Entra ID. The deployer gets the cluster admin role. |
| PostgreSQL Flexible Server 16 | Private only (VNet-injected) | `require_secure_transport=on`. The hstore, uuid-ossp and pg_stat_statements extensions are allow-listed. |
| Azure Managed Redis | Private only (private endpoint) | EnterpriseCluster clustering policy, TLS on port 10000 |
| Blob storage | Private only (private endpoint) | Shared Key is disabled. OSMO uses Workload Identity. |
| Key Vault | Private endpoint, plus a public endpoint open only to admin IPs | Holds the PostgreSQL password and Redis key. Terraform needs the public endpoint to write the secrets. |
| GPU node pool | — | NVIDIA T4, Regular priority, scales to zero. `gpu_driver=None`: the GPU Operator installs the driver. |

Azure Container Registry is out of scope for phase 1. Images are pulled directly from nvcr.io.

## Resource naming

Names follow the [CAF abbreviations](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations)
and the [Azure naming rules](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules).
They are all defined in `naming.tf`:

```
<abbreviation>-<workload>-<environment>-<region>[-<purpose>][-<unique suffix>]
```

| Variable | Default | Notes |
|---|---|---|
| `workload` | `osmo` | Lowercase letters and digits, 2–8 characters |
| `environment` | `poc` | Lowercase letters and digits, 2–5 characters |
| `location_short` | Inferred from the region (westus3 → `wus3`) | Required for regions not in the built-in map |
| `unique_suffix` | First 4 characters of a hash of the subscription ID | Used only for globally unique resources. It is known before deployment and stays the same across redeployments. |
| `resource_group_name` | `rg-<workload>-<environment>-<region>` | Can be overridden on its own |

Default names (`<sfx>` is the unique suffix):

| Resource | Name |
|---|---|
| Resource group / AKS node resource group | `rg-osmo-poc-wus3` / `rg-osmo-poc-wus3-aksnodes` |
| VNet / subnets | `vnet-osmo-poc-wus3` / `snet-aks`, `snet-pep`, `snet-pgsql` |
| NAT gateway / public IP | `ng-osmo-poc-wus3` / `pip-osmo-poc-wus3-ng` |
| AKS / node pools | `aks-osmo-poc-wus3` / `npsystem`, `npgput4` |
| Managed identities | `id-osmo-poc-wus3-aks` (control plane), `id-osmo-poc-wus3-osmo` (OSMO workloads) |
| PostgreSQL | `pgsql-osmo-poc-wus3-<sfx>`, with private DNS zone `osmo-poc-wus3.private.postgres.database.azure.com` |
| Managed Redis | `amr-osmo-poc-wus3-<sfx>` |
| Storage account / container | `stosmopocwus3<sfx>` / `osmo` |
| Key Vault | `kv-osmo-poc-wus3-<sfx>` |
| Private endpoints / NICs | `pep-osmo-poc-wus3-{kv,blob,amr}` / `nic-pep-osmo-poc-wus3-{kv,blob,amr}` |
| Log Analytics / DCR | `log-osmo-poc-wus3` / `dcr-osmo-poc-wus3-ci` |

Some names are fixed and do not follow these variables:
- The `privatelink.*` private DNS zones (names set by Azure)
- The DCR association `ContainerInsightsExtension` (Container Insights convention)
- The Key Vault secrets `postgres-admin-password` and `redis-primary-key`
- The federated credentials `fic-<key>`

During `terraform plan`, `naming.tf` checks the length and allowed characters of the Key Vault, storage account and other constrained names.

## Prerequisites

- Terraform 1.9 or later, and the Azure CLI signed in (`az login`)
- Subscription permissions: Owner, or Contributor plus User Access Administrator, because the module creates role assignments
- **GPU quota.** The `Standard NCASv3_T4 Family vCPUs` quota must cover `gpu_node_max_count × vCPUs per node` (NC8as has 8 vCPUs). Check it with:

  ```bash
  az vm list-usage -l westus3 -o table | grep -i NCAS
  ```

  The GPU node pool is still created when the quota is 0, because its minimum size is 0, but it cannot scale out.
- [kubelogin](https://azure.github.io/kubelogin/) to access the cluster. `az aks install-cli` installs it.

## Deploy

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# Set subscription_id and admin_ip_cidrs (find your egress IP with: curl -s ifconfig.me)

terraform init
terraform plan -out tfplan
terraform apply tfplan
```

Managed Redis is slow to provision, so expect the whole apply to take 20–40 minutes.

Then fetch the cluster credentials:

```bash
$(terraform output -raw aks_get_credentials_command)
kubectl get nodes
```

## Key outputs

| Output | Used for |
|---|---|
| `osmo_identity_client_id` | The `azure.workload.identity/client-id` annotation on OSMO service accounts |
| `postgres_fqdn` / `postgres_db_name` / `postgres_admin_username` | OSMO database connection |
| `redis_hostname` / `redis_port` | OSMO Redis connection (TLS) |
| `storage_account_name` / `storage_container_name` / `storage_blob_endpoint` | Storage for OSMO workflow data, logs and artifacts |
| `key_vault_name` / `key_vault_secret_names` | Retrieving the PostgreSQL password and Redis key through the Key Vault CSI driver |

## Notes

- **Workload Identity service account names.** The defaults in `osmo_workload_identity_subjects` match the OSMO 6.3.1 chart defaults: `osmo` for the service chart, and a backend-operator release named `osmo-operator`. If you change the release names or namespaces when deploying OSMO, update this variable and apply again.
- **Key Vault public endpoint.** Writing secrets is a data-plane operation, so the vault accepts public traffic from `admin_ip_cidrs`. After deployment you can set `public_network_access_enabled` to `false` and apply. From then on, changing secrets requires a jump host inside the VNet.
- **Admin IP changes.** If your egress IP changes, update `admin_ip_cidrs` and apply. Until you do, you cannot reach the AKS API or Key Vault.
- **Sensitive values.** The PostgreSQL password and the Redis key are stored in the Terraform state. The PoC uses local state, so never commit state files. Production should use an encrypted remote backend, such as Azure Storage.
- **Teardown.** `terraform destroy` removes every resource and purges the Key Vault.

## Validation log

- 2026-11-05: With azurerm 5.12.0, azapi 2.13.0 and Terraform 1.17.1, `terraform validate` passed and `terraform plan` against the target subscription passed (48 resources). Not applied yet.
- 2026-11-05: Naming switched to the CAF convention (`naming.tf`). `validate` and `plan` passed again.
