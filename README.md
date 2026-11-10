<a href="https://cast.ai">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/full-logo-white.svg">
    <source media="(prefers-color-scheme: light)" srcset=".github/full-logo-black.svg">
    <img src=".github/full-logo-black.svg" alt="Cast AI logo" title="Cast AI" align="right" height="50">
  </picture>
</a>

AKS to CAST AI onboarding (Terraform root configuration)
==================

Website: https://www.cast.ai

This repository is a standalone Terraform **root configuration**, not a reusable module. You copy it, fill in `terraform.tfvars` and run `terraform apply` from this directory.

It creates the Azure IAM objects CAST AI needs and registers an existing AKS cluster with CAST AI. It does not install anything into the cluster.

It is derived from the CAST AI AKS module (`castai/aks/castai`) and keeps its Apache-2.0 licence.

What it creates
---------------

* `azuread` / `azurerm` authentication resources: a user-assigned managed identity with a federated identity credential (default), or an Entra application, service principal and client secret (`authentication_method = "client_secret"`)
* The custom role `CastAKSRole-<cluster-name>-tf` and its role assignments on `resource_group`, `node_resource_group` and `additional_resource_groups` - **optional**, see [Role creation](#role-creation)
* The CAST AI cluster registration (`castai_aks_cluster`)
* CAST AI-side configuration: node configurations, node templates, autoscaler settings, workload scaling policies and custom metrics data sources

What it does not do
-------------------

There is no `helm_release` and no Kubernetes object in this configuration. Install and upgrade the CAST AI components separately, see [Installing the CAST AI components](#installing-the-cast-ai-components).

Prerequisites
-------------

* Terraform CLI. This configuration is validated with Terraform 1.12.2
* Providers, declared in `versions.tf`: `hashicorp/azurerm >= 5.0.1`, `hashicorp/azuread >= 3.0`, `castai/castai >= 8.57.0`
* Azure credentials allowed to create role definitions and role assignments: `az login`, or `ARM_*` environment variables
* A CAST AI API token: console.cast.ai -> **API access keys**

Usage
-----

```bash
cp terraform.tfvars.example terraform.tfvars
# fill in the values, then:
terraform init
terraform plan
terraform apply
```

Values that must be provided in `terraform.tfvars`:

| Variable | Where it comes from |
|---|---|
| `aks_cluster_name`, `aks_cluster_region`, `resource_group`, `subscription_id` | your AKS cluster |
| `node_resource_group` | `az aks show -g <resource_group> -n <cluster> --query nodeResourceGroup -o tsv` |
| `tenant_id` | `az account show --query tenantId -o tsv` |
| `castai_api_token` | CAST AI Console -> API access keys |
| `node_configurations` and `default_node_configuration` | at least one configuration; `default_node_configuration` must be one of its keys |

`castai_api_url` defaults to `https://api.cast.ai`; set `https://api.eu.cast.ai` for the EU region.

Outputs: `cluster_id`, `organization_id`, `castai_node_configurations`, `castai_node_templates`.

Providers
---------

`providers.tf` configures all three providers from the variables above, so no additional configuration is required:

```hcl
provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

provider "azuread" {
  tenant_id = var.tenant_id
}

provider "castai" {
  api_url   = var.castai_api_url
  api_token = var.castai_api_token
}
```

Role creation
-------------

`create_role` defaults to `true`: the module creates `CastAKSRole-<cluster-name>-tf` and assigns it to the CAST AI principal on `resource_group`, `node_resource_group` and every entry of `additional_resource_groups`.

Set `create_role = false` when the permissions are granted by other means (an existing role, a policy-driven setup, or another Terraform stack):

```hcl
create_role = false
```

No role definition and no role assignment is created in that case. The CAST AI principal still exists, so the required permissions must be granted to it before CAST AI can create, resize or delete nodes.

Authentication
--------------

`authentication_method` selects how CAST AI authenticates to Azure:

* `workload_identity` (default) - a user-assigned managed identity plus a federated identity credential. No long-lived secret.
* `client_secret` - an Entra application with a service principal and a client secret.

`authentication_method_migration` controls the switch between the two methods (`none`, `prepare`, `keep-secret-auth`). Switching from `client_secret` to `workload_identity` destroys the Entra application and its secret; use `keep-secret-auth` to keep the client-secret credentials as a fallback while migrating.

Installing the CAST AI components
---------------------------------

The cluster is registered by `terraform apply`, but the CAST AI components are installed with Helm:

```bash
helm repo add castai-helm https://castai.github.io/helm-charts
helm repo update

helm upgrade --install castai castai-helm/castai -n castai-agent --create-namespace \
  --set global.castai.apiKey=<cluster-token> \
  --set global.castai.provider=aks \
  --set tags.workload-autoscaler=true
```

Replace `<cluster-token>` with the cluster token from the CAST AI console connect instructions; this configuration does not output it. `tags.*` selects the profile (`readonly`, `node-autoscaler`, `workload-autoscaler`, `full`, ...) and the modes are mutually exclusive.

The umbrella chart contains only the CAST AI autoscaler components: `kent`, `autoscaler-anywhere`, `autoscaler-openshift`, `autoscaler` and `readonly-profile`. CAST AI Omni is not part of it and is installed by the separate `castai/omni-cluster/castai` module, so nothing here or in the chart needs to be disabled to avoid it.

State
-----

State is local (`terraform.tfstate`) and is git-ignored, together with `terraform.tfvars` and plan files. For shared or repeated use, configure a remote backend.

If this directory previously ran the module version that installed Helm releases, remove those resources from state before applying, otherwise Terraform plans to uninstall them:

```bash
terraform state list | grep -E '^(helm_release|null_resource\.wait_for_cluster)' | xargs -r -n1 terraform state rm
```

Tests
-----

```bash
terraform init
terraform test
```

The `tests/*.tftest.hcl` files use mocked providers, so they need no cloud access and no credentials.

Repository layout
-----------------

| File | Purpose |
|---|---|
| `providers.tf` | `azurerm`, `azuread` and `castai` provider configuration |
| `versions.tf` | Terraform and provider version constraints |
| `variables.tf` | All inputs, documented in [Inputs](#inputs) |
| `main.tf` | CAST AI cluster registration and CAST AI-side configuration |
| `iam.tf` | Azure role, role assignments, service principal or managed identity |
| `outputs.tf` | Cluster and node configuration identifiers |
| `terraform.tfvars.example` | Template for the local `terraform.tfvars` |
| `tests/` | `terraform test` suites with mocked providers |

Troubleshooting
---------------

* `Invalid provider configuration` - a provider is used but not configured. Keep `providers.tf` in this directory; it is only needed at the root, not in child modules.
* `Missing API Token Configuration` - `castai_api_token` is empty.
* `Value for undeclared variable` - `terraform.tfvars` contains a key that does not exist in `variables.tf`.
* `Missing resource instance key` - a counted resource is referenced without an index, e.g. `azurerm_role_definition.castai[0]`.

Licence
-------

Apache 2.0, see [LICENSE](LICENSE). Derived from [castai/terraform-castai-aks](https://github.com/castai/terraform-castai-aks).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 0.13 |
| <a name="requirement_azuread"></a> [azuread](#requirement\_azuread) | >= 3.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | >= 5.0.1 |
| <a name="requirement_castai"></a> [castai](#requirement\_castai) | >= 8.57.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azuread"></a> [azuread](#provider\_azuread) | >= 3.0 |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | >= 5.0.1 |
| <a name="provider_castai"></a> [castai](#provider\_castai) | >= 8.57.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azuread_application.castai](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/application) | resource |
| [azuread_application_password.castai](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/application_password) | resource |
| [azuread_service_principal.castai](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/service_principal) | resource |
| [azurerm_federated_identity_credential.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/federated_identity_credential) | resource |
| [azurerm_role_assignment.castai_additional_resource_groups](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.castai_node_resource_group](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.castai_resource_group](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_definition.castai](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_definition) | resource |
| [azurerm_user_assigned_identity.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [castai_aks_cluster.castai_cluster](https://registry.terraform.io/providers/castai/castai/latest/docs/resources/aks_cluster) | resource |
| [castai_autoscaler.castai_autoscaler_policies](https://registry.terraform.io/providers/castai/castai/latest/docs/resources/autoscaler) | resource |
| [castai_node_configuration.this](https://registry.terraform.io/providers/castai/castai/latest/docs/resources/node_configuration) | resource |
| [castai_node_configuration_default.this](https://registry.terraform.io/providers/castai/castai/latest/docs/resources/node_configuration_default) | resource |
| [castai_node_template.this](https://registry.terraform.io/providers/castai/castai/latest/docs/resources/node_template) | resource |
| [castai_workload_custom_metrics_data_source.this](https://registry.terraform.io/providers/castai/castai/latest/docs/resources/workload_custom_metrics_data_source) | resource |
| [castai_workload_scaling_policy.this](https://registry.terraform.io/providers/castai/castai/latest/docs/resources/workload_scaling_policy) | resource |
| [azuread_client_config.current](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/data-sources/client_config) | data source |
| [azurerm_kubernetes_cluster.castai](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/kubernetes_cluster) | data source |
| [castai_impersonation_service_account.this](https://registry.terraform.io/providers/castai/castai/latest/docs/data-sources/impersonation_service_account) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_additional_resource_groups"></a> [additional\_resource\_groups](#input\_additional\_resource\_groups) | n/a | `list(string)` | `[]` | no |
| <a name="input_aks_cluster_name"></a> [aks\_cluster\_name](#input\_aks\_cluster\_name) | Name of the cluster to be connected to CAST AI. | `string` | n/a | yes |
| <a name="input_aks_cluster_region"></a> [aks\_cluster\_region](#input\_aks\_cluster\_region) | Region of the AKS cluster | `string` | n/a | yes |
| <a name="input_authentication_method"></a> [authentication\_method](#input\_authentication\_method) | Authentication method for CAST AI. Use 'client\_secret' for service principal with password, or 'workload\_identity' for federated identity credential | `string` | `"workload_identity"` | no |
| <a name="input_authentication_method_migration"></a> [authentication\_method\_migration](#input\_authentication\_method\_migration) | Controls migration to workload-identity authentication as more secure default. 'prepare' pre-provisions the workload identity resources - but they remain unused until the authentication method is switched. 'keep-secret-auth' keeps the client secret resources (Azure AD application, service principal and password) while authenticating with workload identity. 'none' disables any migration behavior. This variable is used for incremental migration and will be removed in the future. | `string` | `"none"` | no |
| <a name="input_autoscaler_settings"></a> [autoscaler\_settings](#input\_autoscaler\_settings) | Optional Autoscaler policy definitions to override current autoscaler settings | `any` | `null` | no |
| <a name="input_azuread_owners"></a> [azuread\_owners](#input\_azuread\_owners) | A set of object IDs of principals that will be granted ownership of the Azure AD service principal and application. Defaults to current user. | `list(string)` | `null` | no |
| <a name="input_ca_certs"></a> [ca\_certs](#input\_ca\_certs) | List of base64-encoded CA certificates to add to the node's trust store. | `list(string)` | `[]` | no |
| <a name="input_castai_api_token"></a> [castai\_api\_token](#input\_castai\_api\_token) | CAST AI API token created in console.cast.ai API Access keys section | `string` | n/a | yes |
| <a name="input_castai_api_url"></a> [castai\_api\_url](#input\_castai\_api\_url) | URL of alternative CAST AI API to be used during development or testing | `string` | `"https://api.cast.ai"` | no |
| <a name="input_create_role"></a> [create\_role](#input\_create\_role) | When true (default), the module creates the custom Azure role definition used by CAST AI and assigns it to the CAST AI principal for `resource_group`, `node_resource_group` and `additional_resource_groups`. When false, only the authentication resources (Azure AD application, service principal and secret, or managed identity and federated identity credential) and the CAST AI cluster registration are created; no role definition or role assignment is created, so the required permissions must be granted by other means. | `bool` | `true` | no |
| <a name="input_default_node_configuration"></a> [default\_node\_configuration](#input\_default\_node\_configuration) | ID of the default node configuration | `string` | `""` | no |
| <a name="input_default_node_configuration_name"></a> [default\_node\_configuration\_name](#input\_default\_node\_configuration\_name) | Name of the default node configuration | `string` | `""` | no |
| <a name="input_delete_nodes_on_disconnect"></a> [delete\_nodes\_on\_disconnect](#input\_delete\_nodes\_on\_disconnect) | Optionally delete Cast AI created nodes when the cluster is destroyed | `bool` | `false` | no |
| <a name="input_http_proxy"></a> [http\_proxy](#input\_http\_proxy) | Address to use for proxying http requests from CAST AI components running directly on nodes. | `string` | `null` | no |
| <a name="input_https_proxy"></a> [https\_proxy](#input\_https\_proxy) | Address to use for proxying https requests from CAST AI components running directly on nodes. | `string` | `null` | no |
| <a name="input_no_proxy"></a> [no\_proxy](#input\_no\_proxy) | List of addresses to skip proxying requests from CAST AI components running directly on nodes. Used with http\_proxy and https\_proxy. | `list(string)` | `[]` | no |
| <a name="input_node_configurations"></a> [node\_configurations](#input\_node\_configurations) | Map of AKS node configurations to create | `any` | `{}` | no |
| <a name="input_node_resource_group"></a> [node\_resource\_group](#input\_node\_resource\_group) | n/a | `string` | n/a | yes |
| <a name="input_node_templates"></a> [node\_templates](#input\_node\_templates) | Map of node templates to create | `any` | `{}` | no |
| <a name="input_resource_group"></a> [resource\_group](#input\_resource\_group) | n/a | `string` | n/a | yes |
| <a name="input_subscription_id"></a> [subscription\_id](#input\_subscription\_id) | Azure subscription ID | `string` | n/a | yes |
| <a name="input_tenant_id"></a> [tenant\_id](#input\_tenant\_id) | n/a | `string` | n/a | yes |
| <a name="input_workload_custom_metrics_data_sources"></a> [workload\_custom\_metrics\_data\_sources](#input\_workload\_custom\_metrics\_data\_sources) | Map of workload custom metrics data sources to create | `any` | `{}` | no |
| <a name="input_workload_scaling_policies"></a> [workload\_scaling\_policies](#input\_workload\_scaling\_policies) | Map of workload scaling policies to create (passed through to castai\_workload\_scaling\_policy).<br/><br/>Apply threshold:<br/>- Prefer cpu/memory.apply\_threshold\_strategy (e.g. { type = "DEFAULT\_ADAPTIVE" } for Dynamic).<br/>- Deprecated apply\_threshold is only set when apply\_threshold\_strategy is absent (default 0.1).<br/>- If both are supplied, strategy wins and apply\_threshold is omitted so older providers<br/>  that mark the fields as conflicting do not fail.<br/><br/>Min/max constraints:<br/>- Prefer cpu/memory.constraints for new configurations.<br/>- Each min/max strategy supports a single field — either constant<br/>  (number, MiB for memory / cores for CPU) or percentage\_of\_original<br/>  (number, percent of the original pod-spec request). Within a single<br/>  min or max strategy only one of constant / percentage\_of\_original may<br/>  be set.<br/>- Legacy cpu/memory.min and cpu/memory.max (plain numbers) are deprecated.<br/>- The module ensures only one style is passed through: if both legacy<br/>  min/max and constraints are supplied for the same resource (cpu or<br/>  memory), constraints takes precedence and the legacy min/max are<br/>  omitted so the provider does not reject the config.<br/><br/>Resource limits (console Automatic / Semi-automatic map to MULTIPLIER + flags):<br/>- limit.only\_if\_original\_exist (bool) — only set limits when the workload originally had them.<br/>- limit.only\_if\_original\_lower (bool) — only raise limits when original limits are lower than<br/>  requests × multiplier.<br/>- Both flags are optional booleans and may be combined; see provider docs for workload\_scaling\_policy.<br/><br/>JVM optimization:<br/>- jvm.auto\_instrument (bool) — when true, JMX exporter is automatically injected<br/>  into pods where a JVM runtime is detected.<br/>- jvm.memory.optimization (bool) — enables JVM heap-size optimization. | `any` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_castai_node_configurations"></a> [castai\_node\_configurations](#output\_castai\_node\_configurations) | Map of node configurations ids by name |
| <a name="output_castai_node_templates"></a> [castai\_node\_templates](#output\_castai\_node\_templates) | Map of node template by name |
| <a name="output_cluster_id"></a> [cluster\_id](#output\_cluster\_id) | CAST.AI cluster id, which can be used for accessing cluster data using API |
| <a name="output_organization_id"></a> [organization\_id](#output\_organization\_id) | CAST.AI organization id of the cluster |<!-- END_TF_DOCS -->
