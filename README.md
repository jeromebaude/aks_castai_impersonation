<a href="https://cast.ai">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/full-logo-white.svg">
    <source media="(prefers-color-scheme: light)" srcset=".github/full-logo-black.svg">
    <img src=".github/full-logo-black.svg" alt="Cast AI logo" title="Cast AI" align="right" height="50">
  </picture>
</a>

Terraform module for connecting a AKS cluster to CAST AI
==================


Website: https://www.cast.ai

Requirements
------------

- [Terraform](https://www.terraform.io/downloads.html) 0.13+

Using the module
------------

A module to create Azure role and a service principal that can be used to connect to CAST AI

This module does **not** install CAST AI components into the cluster and runs no Helm command. It creates the Azure IAM objects (role definition and role assignments, service principal with a client secret or a managed identity with a federated identity credential), the CAST AI cluster registration, and the CAST AI-side configuration (node configurations and templates, autoscaler settings, workload scaling policies, custom metrics data sources). Install and upgrade the CAST AI Helm charts separately, for example with the umbrella chart or the standalone charts.

Requires `castai/castai`, `hashicorp/azurerm`, `hashicorp/azuread` providers to be configured.

The required parameters can be provided manually or alternatively can be easily acquired from your AKS cluster resource or Azure RM subscription data source.

```hcl
module "castai-aks-cluster" {
  source = "castai/aks/castai"

  aks_cluster_name    = var.aks_cluster_name
  aks_cluster_region  = var.aks_cluster_region
  node_resource_group = azurerm_kubernetes_cluster.example.node_resource_group
  resource_group      = azurerm_kubernetes_cluster.example.resource_group_name

  delete_nodes_on_disconnect = true

  subscription_id = data.azurerm_subscription.current.subscription_id
  tenant_id       = data.azurerm_subscription.current.tenant_id

  default_node_configuration = module.castai-aks-cluster.castai_node_configurations["default"]

  node_configurations = {
    default = {
      disk_cpu_ratio = 25
      subnets        = [azurerm_subnet.internal.id]
      tags           = {
        "node-config" : "default"
      }
    }
  }
  node_templates = {
    spot_tmpl = {
      configuration_id = module.castai-aks-cluster.castai_node_configurations["default"]

      should_taint = true

      custom_labels = {
        custom-label-key-1 = "custom-label-value-1"
        custom-label-key-2 = "custom-label-value-2"
      }

      custom_taints = [
        {
          key = "custom-taint-key-1"
          value = "custom-taint-value-1"
        },
        {
          key = "custom-taint-key-2"
          value = "custom-taint-value-2"
        }
      ]

      constraints = {
        fallback_restore_rate_seconds = 1800
        spot = true
        use_spot_fallbacks = true
        min_cpu = 4
        max_cpu = 100
        instance_families = {
          exclude = ["standard_DPLSv5"]
        }
        compute_optimized_state = "disabled"
        storage_optimized_state = "disabled"
      }
    }
  }

  autoscaler_settings = {
    enabled                                 = true
    node_templates_partial_matching_enabled = false

    unschedulable_pods = {
      enabled = true
    }

    node_downscaler = {
      enabled = true

      empty_nodes = {
        enabled = true
      }

      evictor = {
        aggressive_mode           = false
        cycle_interval            = "5s10s"
        dry_run                   = false
        enabled                   = true
        node_grace_period_minutes = 10
        scoped_mode               = false
      }
    }

    cluster_limits = {
      enabled = true

      cpu = {
        max_cores = 20
        min_cores = 1
      }
    }
  }

  workload_scaling_policies = {
    default = {
      apply_type        = "IMMEDIATE"
      management_option = "MANAGED"

      cpu = {
        function                 = "QUANTILE"
        args                     = ["0.9"]
        overhead                 = 0.15
        look_back_period_seconds = 172800

        # Prefer the new constraints block. Within each min/max strategy only
        # one of `constant` or `percentage_of_original` may be set. Legacy
        # `min`/`max` (plain numbers) are still accepted for backward
        # compatibility, but if both legacy `min`/`max` and `constraints`
        # are supplied for the same resource, `constraints` takes precedence
        # and the module omits the legacy `min`/`max` so the provider does
        # not reject the config.
        constraints = {
          min = {
            constant = 0.1
          }
          max = {
            constant = 2.0
          }
        }
      }

      memory = {
        function                 = "MAX"
        overhead                 = 0.35
        look_back_period_seconds = 172800

        limit = {
          type = "NO_LIMIT"
        }
      }

      assignment_rules = {
        rules = [
          {
            namespace = {
              names = ["default", "kube-system"]
            }
          },
          {
            workload = {
              gvk = ["Deployment", "StatefulSet"]
              labels_expressions = [
                {
                  key      = "region"
                  operator = "NotIn"
                  values   = ["eu-west-1", "eu-west-2"]
                },
                {
                  key      = "helm.sh/chart"
                  operator = "Exists"
                }
              ]
            }
          }
        ]
      }

      startup = {
        period_seconds = 300
        two_phase_recommendations = {
          enabled = true
          requests_on_startup = {
            cpu_cores  = 0.5
            memory_gib = 1.5
          }
        }
      }

      predictive_scaling = {
        cpu = {
          enabled = true
        }
      }

      jvm = {
        auto_instrument = true
        memory = {
          optimization = true
        }
      }

      anomaly_detection = {
        cpu_pressure = {
          cpu_stall_threshold_percentage = 50
          min_pressured_pod_percentage   = 30
        }
      }

      excluded_containers = ["container-1", "container-2"]

      # Convert existing HPA utilization (%) targets to AverageValue using the
      # workload's original container requests. Ignored if HPA management is enabled.
      hpa_converters = [
        {
          type = "AVERAGE_VALUE_FROM_ORIGINAL_REQUESTS"
        }
      ]
    }
  }

  workload_custom_metrics_data_sources = {
    my-prometheus = {
      prometheus = {
        url     = "http://prometheus-server.monitoring.svc.cluster.local:9090"
        timeout = "30s"
        presets = ["jvm"]

        metrics = [
          {
            name  = "http_requests_total"
            query = "sum(rate(http_requests_total[5m])) by (pod)"
          }
        ]
      }
    }
  }
}
```

Optional Azure role
-------------------

By default the module creates the custom role definition `CastAKSRole-<cluster-name>-tf` and assigns it to the CAST AI principal on `resource_group`, `node_resource_group` and every entry of `additional_resource_groups`. Set `create_role = false` when the permissions are granted by other means (an existing role, a policy-driven setup, or another Terraform stack):

```hcl
module "castai-aks-cluster" {
  source = "castai/aks/castai"

  # ... required parameters ...

  create_role = false
}
```

No role definition and no role assignment is created in that case. The CAST AI principal still exists (`workload_identity` or `client_secret` authentication), so the required permissions must be granted to it before CAST AI can create, resize or delete nodes.

Migrating from 2.x.x to 3.x.x
---------------------------

Version 3.x.x changes:
* Removed `custom_label` attribute in `castai_node_template` resource. Use `custom_labels` instead.

Old configuration:
```terraform
module "castai-aks-cluster" {
  node_templates = {
    spot_tmpl = {
      custom_label = {
        key = "custom-label-key-1"
        value = "custom-label-value-1"
      }
    }
  }
}
```

New configuration:
```terraform
module "castai-aks-cluster" {
  node_templates = {
    spot_tmpl = {
      custom_labels = {
        custom-label-key-1 = "custom-label-value-1"
      }
    }
  }
}
```
Migrating from 3.x.x to 4.x.x
---------------------------

Version 4.x.x changed:
* Removed `compute_optimized` and `storage_optimized` attributes in `castai_node_template` resource, `constraints` object. Use `compute_optimized_state` and `storage_optimized_state` instead.

Old configuration:
```terraform
module "castai-aks-cluster" {
  node_templates = {
    spot_tmpl = {
      constraints = {
        compute_optimized = false
        storage_optimized = true
      }
    }
  }
}
```

New configuration:
```terraform
module "castai-aks-cluster" {
  node_templates = {
    spot_tmpl = {
      constraints = {
        compute_optimized_state = "disabled"
        storage_optimized_state = "enabled"
      }
    }
  }
}
```

Migrating from 5.0.x to 5.2.x
---------------------------

Version 5.2.x changed:
* Deprecated `autoscaler_policies_json` attribute. Use `autoscaler_settings` instead.

Old configuration:
```hcl
module "castai-aks-cluster" {
  autoscaler_policies_json = <<-EOT
    {
        "enabled": true,
        "unschedulablePods": {
            "enabled": true
        },
        "nodeDownscaler": {
            "enabled": true,
            "emptyNodes": {
                "enabled": true
            },
            "evictor": {
                "aggressiveMode": false,
                "cycleInterval": "5m10s",
                "dryRun": false,
                "enabled": true,
                "nodeGracePeriodMinutes": 10,
                "scopedMode": false
            }
        },
        "nodeTemplatesPartialMatchingEnabled": false,
        "clusterLimits": {
            "cpu": {
                "maxCores": 20,
                "minCores": 1
            },
            "enabled": true
        }
    }
  EOT
}
```

New configuration:
```hcl
module "castai-aks-cluster" {
  autoscaler_settings = {
    enabled                                 = true
    node_templates_partial_matching_enabled = false

    unschedulable_pods = {
      enabled = true
    }

    node_downscaler = {
      enabled = true

      empty_nodes = {
        enabled = true
      }

      evictor = {
        aggressive_mode           = false
        cycle_interval            = "5m10s"
        dry_run                   = false
        enabled                   = true
        node_grace_period_minutes = 10
        scoped_mode               = false
      }
    }

    cluster_limits = {
      enabled = true

      cpu = {
        max_cores = 20
        min_cores = 1
      }
    }
  }
}
```

Migrating from 9.x.x to 10.x.x
---------------------------

Version 10.x.x removes deprecated autoscaler fields that have been moved to node templates.

**Removed:**
* `autoscaler_policies_json` - Use `autoscaler_settings` instead
* `autoscaler_settings.unschedulable_pods.custom_instances_enabled` - No longer needed
* `autoscaler_settings.unschedulable_pods.headroom` - Use low-priority placeholder workloads instead
* `autoscaler_settings.unschedulable_pods.headroom_spot` - Use low-priority placeholder workloads instead
* `autoscaler_settings.unschedulable_pods.node_constraints` - Use `node_templates` constraints instead
* `autoscaler_settings.spot_instances` - Use `node_templates` constraints instead

**Migration guide:**

Old configuration:
```hcl
module "castai-aks-cluster" {
  source = "castai/aks/castai"

  autoscaler_settings = {
    enabled = true

    unschedulable_pods = {
      enabled                  = true
      custom_instances_enabled = true

      headroom = {
        enabled           = true
        cpu_percentage    = 10
        memory_percentage = 10
      }

      node_constraints = {
        min_cpu_cores = 4
        max_cpu_cores = 32
      }
    }

    spot_instances = {
      enabled = true
      spot_backups = {
        enabled = true
      }
    }
  }
}
```

New configuration:
```hcl
module "castai-aks-cluster" {
  source = "castai/aks/castai"

  autoscaler_settings = {
    enabled = true

    unschedulable_pods = {
      enabled = true
    }
  }

  node_templates = {
    default_by_castai = {
      configuration_id = module.castai-aks-cluster.castai_node_configurations["default"]
      is_default       = true

      constraints = {
        min_cpu            = 4
        max_cpu            = 32
        spot               = true
        use_spot_fallbacks = true
      }
    }
  }
}

# For headroom: Deploy low-priority placeholder workloads
# See: https://docs.cast.ai/docs/autoscaler-faq#how-can-i-maintain-cluster-headroom
```

**Key changes:**
* Node constraints (`min_cpu_cores`, `max_cpu_cores`, `min_ram_mib`, `max_ram_mib`) are now configured in `node_templates.constraints` as `min_cpu`, `max_cpu`, `min_memory`, `max_memory`
* Spot instance settings (`spot`, `use_spot_fallbacks`) are now configured in `node_templates.constraints`
* The default node template is named `default_by_castai`
* For headroom functionality, deploy low-priority placeholder workloads as described in the [CAST AI documentation](https://docs.cast.ai/docs/autoscaler-faq#how-can-i-maintain-cluster-headroom)

Workload identity migration tooling (added in 12.1.x)
-----------------------------------------------------

Workload identity is the default authentication method from version 13.0.0. Switching an existing cluster from `client_secret` deletes the Azure AD application and its client secret, and a failed apply could leave the cluster disconnected. To make the switch safe and incremental, version 12.1.x introduced the `authentication_method_migration` variable:

* `prepare`: pre-provisions the workload identity resources (a user-assigned managed identity and a federated identity credential) while the module continues to authenticate with `client_secret`. They are not used for authentication and the managed identity receives no role assignments until `authentication_method` is switched, but they allow switching later without creating anything at cutover time. This enables validating that the resources can be created safely. Has no effect if `authentication_method` is `workload_identity`.
* `keep-secret-auth` (added in 13.0.0): keeps the Azure AD application, service principal and client secret while authenticating with `workload_identity`. Use this to retain the client-secret credentials as a fallback while (or after) switching over - otherwise they are destroyed when `authentication_method` changes and have to be recreated on rollback. This mode has no practical effect while `authentication_method` is `client_secret`. Once cluster is safely migrated to workload identity, the migration can be set to `none` to clean up.
* `none` (default from 13.0.0): no migration behavior - no additional resources are created, no additional permissions are required, and behavior remains exactly as-is.

In the 12.1.x-12.x.x releases, `prepare` was the default so the resources exist ahead of the switch. From 13.0.0 the default is `none`, which automatically cleans up the unused pre-provisioned resources for anyone who had not switched to `workload_identity` yet. If the resources were used as preparation for the switch performed in the same upgrade, they simply stay in use and only the client secret resources are removed.

Migrating from 12.x.x to 13.x.x
-------------------------------

Version 13.0.0 introduces a new default for the authentication method used by CAST AI to access cloud environments. This new authentication method offers better security by utilizing federated identity and no long-living credentials on CAST AI side. The behavior is controlled by the `authentication_method` variable and its default switches from `client_secret` to `workload_identity`.

To opt-out of the changes, set `authentication_method = "client_secret"` before applying the changes from v13. More details on the settings below.

If the value of the variable was previously set to any value, there is no change in behavior. However, if no value was set and the default was used, upgrading the module will cause the `client_secret` IAM resources to be reconfigured for workload identity - a new managed identity with federated credential is created, while the existing Entra application will be destroyed. To keep the existing Entra application and its client secret instead of destroying them, set `authentication_method_migration = "keep-secret-auth"` (see the migration tooling section above).

> [!CAUTION]
> While applying the changes, it is possible that CAST AI loses access temporarily while credentials are being reconfigured. In addition, failure to configure Workload identity but successful client secret destruction might lead to loss of access for cluster management by CAST AI. It is recommended that the change is monitored and done carefully.

> [!NOTE]
> Rolling back to client secret flow after switching to workload identity will create a new Entra application client ID for access - consider that if roles or policies are attached to the application.

If users are using 11.x.x or older, it is recommended that migration to 12.x.x is completed as a separate step from 13.x.x, as both involve delicate migrations. In addition, the standalone releases mentioned in 12.x.x are kept for this release and still available.

Migrating from 13.x.x to the Helm-free release
----------------------------------------------

This release stops managing CAST AI components in the cluster. The module no longer installs or upgrades anything with Helm:

* every `helm_release` resource is removed (standalone charts and the umbrella chart), together with the `helm` and `null` provider requirements;
* `null_resource.wait_for_cluster` is removed, together with the `wait_for_cluster_ready` and `castai_api_token` inputs;
* the Omni capability is removed (`install_omni`), because it installs its operators with Helm;
* all chart inputs are removed: `<chart>_values`, `<chart>_version`, `install_*`, `self_managed`, `umbrella_enabled`, `workload_autoscaler_keep_crds`, `overwrite_existing_helm_releases`, `castai_components_labels`, `castai_components_sets`, `api_url`, `grpc_url`, `kvisor_grpc_addr`, `kvisor_controller_extra_args` and `organization_id`.

Install and upgrade the CAST AI components separately. The module keeps the Azure IAM resources, the CAST AI cluster registration, node configurations and templates, autoscaler settings, workload scaling policies, custom metrics data sources and the `create_role` switch described above.

> [!CAUTION]
> Applying this release while the Helm releases above are still in the Terraform state plans their **destruction**, which runs `helm uninstall` and removes the CAST AI components from the cluster. To keep the components installed and manage them outside of this module, remove them from the state first:
>
> ```bash
> terraform state list | grep -E '^(helm_release|null_resource\.wait_for_cluster)' | xargs -r -n1 terraform state rm
> ```
>
> Then remove the deleted inputs from the module block. Upgrading from 11.x.x or older to this release still requires completing the 12.x.x umbrella migration first if you want to keep using the Helm charts.

# Examples 

Usage examples are located in [terraform provider repo](https://github.com/castai/terraform-provider-castai/tree/master/examples/aks)

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
