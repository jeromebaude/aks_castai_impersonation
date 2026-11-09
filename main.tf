locals {
  configuration_id_regex_pattern = "[a-zA-Z0-9]{8}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{12}"
  has_http_proxy                 = length(var.no_proxy) > 0 || (var.http_proxy != null && var.http_proxy != "") || (var.https_proxy != null && var.https_proxy != "")
}

resource "castai_aks_cluster" "castai_cluster" {
  name = var.aks_cluster_name

  region          = var.aks_cluster_region
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  client_id       = var.authentication_method == "client_secret" ? azuread_application.castai[0].client_id : azurerm_user_assigned_identity.this[0].client_id
  client_secret   = var.authentication_method == "client_secret" ? azuread_application_password.castai[0].value : null
  federation_id   = var.authentication_method == "workload_identity" ? azurerm_user_assigned_identity.this[0].principal_id : null

  node_resource_group        = var.node_resource_group
  delete_nodes_on_disconnect = var.delete_nodes_on_disconnect

  dynamic "http_proxy_config" {
    for_each = local.has_http_proxy ? [true] : []

    content {
      http_proxy  = try(var.http_proxy, null)
      https_proxy = try(var.https_proxy, null)
      no_proxy    = try(var.no_proxy, [])
    }
  }

  dynamic "ca_cert_config" {
    for_each = length(var.ca_certs) > 0 ? [true] : []

    content {
      ca_certs = var.ca_certs
    }
  }

  # CastAI needs cloud permission to do some clean up
  # when disconnecting the cluster.
  # This ensures IAM configurations exist during disconnect.
  depends_on = [
    azurerm_role_definition.castai,
    azurerm_role_assignment.castai_resource_group,
    azurerm_role_assignment.castai_node_resource_group,
    azurerm_role_assignment.castai_additional_resource_groups,
    azuread_application.castai,
    azuread_application_password.castai,
    azuread_service_principal.castai,
    azurerm_user_assigned_identity.this,
    azurerm_federated_identity_credential.this
  ]
}

resource "castai_node_configuration" "this" {
  for_each = { for k, v in var.node_configurations : k => v }

  cluster_id = castai_aks_cluster.castai_cluster.id

  name              = try(each.value.name, each.key)
  disk_cpu_ratio    = try(each.value.disk_cpu_ratio, 0)
  drain_timeout_sec = try(each.value.drain_timeout_sec, 0)
  min_disk_size     = try(each.value.min_disk_size, 100)
  subnets           = try(each.value.subnets, null)
  ssh_public_key    = try(each.value.ssh_public_key, null)
  image             = try(each.value.image, null)
  tags              = try(each.value.tags, {})

  aks {
    max_pods_per_node = try(each.value.max_pods_per_node, 30)
    os_disk_type      = try(each.value.os_disk_type, null)
    aks_image_family  = try(each.value.aks_image_family, null)
    pod_subnet_id     = try(each.value.pod_subnet_id, null)
    dynamic "ephemeral_os_disk" {
      for_each = flatten([lookup(each.value, "aks_ephemeral_os_disk", [])])
      content {
        placement = try(ephemeral_os_disk.value.placement, null)
        cache     = try(ephemeral_os_disk.value.cache, null)
      }
    }
    dynamic "loadbalancers" {
      for_each = flatten([lookup(each.value, "loadbalancers", [])])

      content {
        id   = try(loadbalancers.value.id, null)
        name = try(loadbalancers.value.name, null)

        dynamic "ip_based_backend_pools" {
          for_each = flatten([lookup(loadbalancers.value, "ip_based_backend_pools", [])])

          content {
            name = try(ip_based_backend_pools.value.name, null)
          }
        }

        dynamic "nic_based_backend_pools" {
          for_each = flatten([lookup(loadbalancers.value, "nic_based_backend_pools", [])])

          content {
            name = try(nic_based_backend_pools.value.name, null)
          }
        }
      }
    }

    network_security_group      = try(each.value.network_security_group, null)
    application_security_groups = try(each.value.application_security_groups, null)
    dynamic "public_ip" {
      for_each = lookup(each.value, "public_ip", null) != null ? [each.value.public_ip] : []

      content {
        public_ip_prefix        = try(public_ip.value.public_ip_prefix, null)
        tags                    = try(public_ip.value.tags, {})
        idle_timeout_in_minutes = try(public_ip.value.idle_timeout_in_minutes, null)
      }
    }

  }
}

resource "castai_node_configuration_default" "this" {
  cluster_id       = castai_aks_cluster.castai_cluster.id
  configuration_id = var.default_node_configuration_name != "" ? castai_node_configuration.this[var.default_node_configuration_name].id : length(regexall(local.configuration_id_regex_pattern, var.default_node_configuration)) > 0 ? var.default_node_configuration : castai_node_configuration.this[var.default_node_configuration].id

  depends_on = [castai_node_configuration.this]
}

resource "castai_node_template" "this" {
  for_each = { for k, v in var.node_templates : k => v }

  cluster_id = castai_aks_cluster.castai_cluster.id

  name                         = try(each.value.name, each.key)
  is_default                   = try(each.value.is_default, false)
  is_enabled                   = try(each.value.is_enabled, null)
  configuration_id             = try(each.value.configuration_name, null) != null ? castai_node_configuration.this[each.value.configuration_name].id : can(each.value.configuration_id) ? length(regexall(local.configuration_id_regex_pattern, each.value.configuration_id)) > 0 ? each.value.configuration_id : castai_node_configuration.this[each.value.configuration_id].id : null
  should_taint                 = try(each.value.should_taint, true)
  clm_enabled                  = try(each.value.clm_enabled, false)
  rebalancing_config_min_nodes = try(each.value.rebalancing_config_min_nodes, 0)

  custom_labels = try(each.value.custom_labels, {})

  dynamic "custom_taints" {
    for_each = flatten([lookup(each.value, "custom_taints", [])])

    content {
      key    = try(custom_taints.value.key, null)
      value  = try(custom_taints.value.value, null)
      effect = try(custom_taints.value.effect, null)
    }
  }

  edge_location_ids = try(each.value.edge_location_ids, null)

  dynamic "constraints" {
    for_each = [for constraints in flatten([lookup(each.value, "constraints", [])]) : constraints if constraints != null]

    content {
      compute_optimized                             = try(constraints.value.compute_optimized, null)
      storage_optimized                             = try(constraints.value.storage_optimized, null)
      compute_optimized_state                       = try(constraints.value.compute_optimized_state, "")
      storage_optimized_state                       = try(constraints.value.storage_optimized_state, "")
      spot                                          = try(constraints.value.spot, false)
      on_demand                                     = try(constraints.value.on_demand, null)
      use_spot_fallbacks                            = try(constraints.value.use_spot_fallbacks, false)
      fallback_restore_rate_seconds                 = try(constraints.value.fallback_restore_rate_seconds, null)
      enable_spot_diversity                         = try(constraints.value.enable_spot_diversity, false)
      spot_diversity_price_increase_limit_percent   = try(constraints.value.spot_diversity_price_increase_limit_percent, null)
      spot_reliability_enabled                      = try(constraints.value.spot_reliability_enabled, false)
      spot_reliability_price_increase_limit_percent = try(constraints.value.spot_reliability_price_increase_limit_percent, null)
      spot_interruption_predictions_enabled         = try(constraints.value.spot_interruption_predictions_enabled, false)
      spot_interruption_predictions_type            = try(constraints.value.spot_interruption_predictions_type, null)
      min_cpu                                       = try(constraints.value.min_cpu, null)
      max_cpu                                       = try(constraints.value.max_cpu, null)
      min_memory                                    = try(constraints.value.min_memory, null)
      max_memory                                    = try(constraints.value.max_memory, null)
      architectures                                 = try(constraints.value.architectures, ["amd64"])
      architecture_priority                         = try(constraints.value.architecture_priority, [])
      os                                            = try(constraints.value.os, ["linux"])
      azs                                           = try(constraints.value.azs, null)
      burstable_instances                           = try(constraints.value.burstable_instances, null)
      customer_specific                             = try(constraints.value.customer_specific, null)
      cpu_manufacturers                             = try(constraints.value.cpu_manufacturers, null)
      is_gpu_only                                   = try(constraints.value.is_gpu_only, false)

      dynamic "instance_families" {
        for_each = [for instance_families in flatten([lookup(constraints.value, "instance_families", [])]) : instance_families if instance_families != null]

        content {
          include = try(instance_families.value.include, [])
          exclude = try(instance_families.value.exclude, [])
        }
      }

      dynamic "custom_priority" {
        for_each = [for custom_priority in flatten([lookup(constraints.value, "custom_priority", [])]) : custom_priority if custom_priority != null]

        content {
          instance_families = try(custom_priority.value.instance_families, [])
          spot              = try(custom_priority.value.spot, false)
          on_demand         = try(custom_priority.value.on_demand, false)
        }
      }

      dynamic "gpu" {
        for_each = [for gpu in flatten([lookup(constraints.value, "gpu", [])]) : gpu if gpu != null]

        content {
          manufacturers = try(gpu.value.manufacturers, [])
          include_names = try(gpu.value.include_names, [])
          exclude_names = try(gpu.value.exclude_names, [])
          min_count     = try(gpu.value.min_count, null)
          max_count     = try(gpu.value.max_count, null)
        }
      }

      dynamic "resource_limits" {
        for_each = [for resource_limits in flatten([lookup(constraints.value, "resource_limits", [])]) : resource_limits if resource_limits != null]

        content {
          cpu_limit_enabled   = try(resource_limits.value.cpu_limit_enabled, false)
          cpu_limit_max_cores = try(resource_limits.value.cpu_limit_max_cores, 0)
        }
      }
    }
  }
  depends_on = [castai_autoscaler.castai_autoscaler_policies]
}

resource "castai_workload_scaling_policy" "this" {
  for_each = { for k, v in var.workload_scaling_policies : k => v }

  name       = try(each.value.name, each.key)
  cluster_id = castai_aks_cluster.castai_cluster.id

  apply_type        = try(each.value.apply_type, "DEFERRED")
  management_option = try(each.value.management_option, "READ_ONLY")

  excluded_containers = try(each.value.excluded_containers, null)

  cpu {
    function = try(each.value.cpu.function, "QUANTILE")
    overhead = try(each.value.cpu.overhead, 0)
    # Deprecated apply_threshold conflicts with apply_threshold_strategy on older providers;
    # omit it when strategy is set so Dynamic/adaptive strategies can be configured.
    apply_threshold          = try(each.value.cpu.apply_threshold_strategy, null) != null ? null : try(each.value.cpu.apply_threshold, 0.1)
    args                     = try(each.value.cpu.args, ["0.8"])
    look_back_period_seconds = try(each.value.cpu.look_back_period_seconds, null)
    # Deprecated min/max conflict with the new constraints block; omit legacy
    # min/max when constraints are supplied so older providers do not fail.
    min = (
      try(each.value.cpu.constraints.min, null) != null ||
      try(each.value.cpu.constraints.max, null) != null
    ) ? null : try(each.value.cpu.min, null)
    max = (
      try(each.value.cpu.constraints.min, null) != null ||
      try(each.value.cpu.constraints.max, null) != null
    ) ? null : try(each.value.cpu.max, null)
    management_option = try(each.value.cpu.management_option, null)

    dynamic "apply_threshold_strategy" {
      for_each = try([each.value.cpu.apply_threshold_strategy], [])
      content {
        type        = try(apply_threshold_strategy.value.type, null)
        percentage  = try(apply_threshold_strategy.value.percentage, null)
        numerator   = try(apply_threshold_strategy.value.numerator, null)
        denominator = try(apply_threshold_strategy.value.denominator, null)
        exponent    = try(apply_threshold_strategy.value.exponent, null)
      }
    }

    dynamic "constraints" {
      for_each = (
        try(each.value.cpu.constraints.min, null) != null ||
        try(each.value.cpu.constraints.max, null) != null
      ) ? [each.value.cpu.constraints] : []
      content {
        dynamic "min" {
          for_each = try([constraints.value.min], [])
          content {
            constant               = try(min.value.constant, null)
            percentage_of_original = try(min.value.percentage_of_original, null)
          }
        }
        dynamic "max" {
          for_each = try([constraints.value.max], [])
          content {
            constant               = try(max.value.constant, null)
            percentage_of_original = try(max.value.percentage_of_original, null)
          }
        }
      }
    }

    dynamic "limit" {
      for_each = try([each.value.cpu.limit], [])
      content {
        type                   = try(limit.value.type, null)
        multiplier             = try(limit.value.multiplier, null)
        only_if_original_exist = try(limit.value.only_if_original_exist, null)
        only_if_original_lower = try(limit.value.only_if_original_lower, null)
      }
    }
  }

  memory {
    function = try(each.value.memory.function, "MAX")
    overhead = try(each.value.memory.overhead, 0.1)
    # Deprecated apply_threshold conflicts with apply_threshold_strategy on older providers;
    # omit it when strategy is set so Dynamic/adaptive strategies can be configured.
    apply_threshold          = try(each.value.memory.apply_threshold_strategy, null) != null ? null : try(each.value.memory.apply_threshold, 0.1)
    args                     = try(each.value.memory.args, null)
    look_back_period_seconds = try(each.value.memory.look_back_period_seconds, null)
    # Deprecated min/max conflict with the new constraints block; omit legacy
    # min/max when constraints are supplied so older providers do not fail.
    min = (
      try(each.value.memory.constraints.min, null) != null ||
      try(each.value.memory.constraints.max, null) != null
    ) ? null : try(each.value.memory.min, null)
    max = (
      try(each.value.memory.constraints.min, null) != null ||
      try(each.value.memory.constraints.max, null) != null
    ) ? null : try(each.value.memory.max, null)
    management_option = try(each.value.memory.management_option, null)

    dynamic "apply_threshold_strategy" {
      for_each = try([each.value.memory.apply_threshold_strategy], [])
      content {
        type        = try(apply_threshold_strategy.value.type, null)
        percentage  = try(apply_threshold_strategy.value.percentage, null)
        numerator   = try(apply_threshold_strategy.value.numerator, null)
        denominator = try(apply_threshold_strategy.value.denominator, null)
        exponent    = try(apply_threshold_strategy.value.exponent, null)
      }
    }

    dynamic "constraints" {
      for_each = (
        try(each.value.memory.constraints.min, null) != null ||
        try(each.value.memory.constraints.max, null) != null
      ) ? [each.value.memory.constraints] : []
      content {
        dynamic "min" {
          for_each = try([constraints.value.min], [])
          content {
            constant               = try(min.value.constant, null)
            percentage_of_original = try(min.value.percentage_of_original, null)
          }
        }
        dynamic "max" {
          for_each = try([constraints.value.max], [])
          content {
            constant               = try(max.value.constant, null)
            percentage_of_original = try(max.value.percentage_of_original, null)
          }
        }
      }
    }

    dynamic "limit" {
      for_each = try([each.value.memory.limit], [])
      content {
        type                   = try(limit.value.type, null)
        multiplier             = try(limit.value.multiplier, null)
        only_if_original_exist = try(limit.value.only_if_original_exist, null)
        only_if_original_lower = try(limit.value.only_if_original_lower, null)
      }
    }
  }

  dynamic "assignment_rules" {
    for_each = try([each.value.assignment_rules], [])
    content {
      dynamic "rules" {
        for_each = try(assignment_rules.value.rules, [])
        content {
          dynamic "namespace" {
            for_each = try([rules.value.namespace], [])
            content {
              names = try(namespace.value.names, null)
            }
          }

          dynamic "workload" {
            for_each = try([rules.value.workload], [])
            content {
              gvk = try(workload.value.gvk, null)

              dynamic "labels_expressions" {
                for_each = try(workload.value.labels_expressions, [])
                content {
                  key      = try(labels_expressions.value.key, null)
                  operator = try(labels_expressions.value.operator, null)
                  values   = try(labels_expressions.value.values, null)
                }
              }
            }
          }
        }
      }
    }
  }

  dynamic "confidence" {
    for_each = try([each.value.confidence], [])
    content {
      threshold = try(confidence.value.threshold, null)
    }
  }

  dynamic "startup" {
    for_each = try([each.value.startup], [])
    content {
      period_seconds = try(startup.value.period_seconds, null)

      dynamic "two_phase_recommendations" {
        for_each = try([startup.value.two_phase_recommendations], [])
        content {
          enabled = try(two_phase_recommendations.value.enabled, null)

          dynamic "requests_on_startup" {
            for_each = try([two_phase_recommendations.value.requests_on_startup], [])
            content {
              cpu_cores  = try(requests_on_startup.value.cpu_cores, null)
              memory_gib = try(requests_on_startup.value.memory_gib, null)
            }
          }
        }
      }
    }
  }

  dynamic "downscaling" {
    for_each = try([each.value.downscaling], [])
    content {
      apply_type = try(downscaling.value.apply_type, null)
    }
  }

  dynamic "memory_event" {
    for_each = try([each.value.memory_event], [])
    content {
      apply_type = try(memory_event.value.apply_type, null)
    }
  }

  dynamic "anti_affinity" {
    for_each = try([each.value.anti_affinity], [])
    content {
      consider_anti_affinity = try(anti_affinity.value.consider_anti_affinity, null)
    }
  }

  dynamic "predictive_scaling" {
    for_each = try([each.value.predictive_scaling], [])
    content {
      dynamic "cpu" {
        for_each = try([predictive_scaling.value.cpu], [])
        content {
          enabled = try(cpu.value.enabled, null)
        }
      }
    }
  }

  dynamic "rollout_behavior" {
    for_each = try([each.value.rollout_behavior], [])
    content {
      type              = try(rollout_behavior.value.type, null)
      prefer_one_by_one = try(rollout_behavior.value.prefer_one_by_one, null)
    }
  }

  dynamic "jvm" {
    for_each = try([each.value.jvm], [])
    content {
      auto_instrument = try(jvm.value.auto_instrument, null)

      dynamic "memory" {
        for_each = try([jvm.value.memory], [])
        content {
          optimization = try(memory.value.optimization, null)
        }
      }
    }
  }

  dynamic "anomaly_detection" {
    for_each = try([each.value.anomaly_detection], [])
    content {
      dynamic "cpu_pressure" {
        for_each = try([anomaly_detection.value.cpu_pressure], [])
        content {
          cpu_stall_threshold_percentage = try(cpu_pressure.value.cpu_stall_threshold_percentage, null)
          min_pressured_pod_percentage   = try(cpu_pressure.value.min_pressured_pod_percentage, null)
        }
      }
    }
  }

  dynamic "hpa_converters" {
    for_each = try(each.value.hpa_converters, [])
    content {
      type = hpa_converters.value.type
    }
  }

}

resource "castai_workload_custom_metrics_data_source" "this" {
  for_each = { for k, v in var.workload_custom_metrics_data_sources : k => v }

  cluster_id = castai_aks_cluster.castai_cluster.id
  name       = try(each.value.name, each.key)

  prometheus {
    url     = each.value.prometheus.url
    timeout = try(each.value.prometheus.timeout, null)
    presets = try(each.value.prometheus.presets, null)

    dynamic "metric" {
      for_each = try(each.value.prometheus.metrics, [])
      content {
        name  = metric.value.name
        query = metric.value.query
      }
    }
  }

}

resource "castai_autoscaler" "castai_autoscaler_policies" {
  cluster_id = castai_aks_cluster.castai_cluster.id

  dynamic "autoscaler_settings" {
    for_each = var.autoscaler_settings != null ? [var.autoscaler_settings] : []

    content {
      enabled                                 = try(autoscaler_settings.value.enabled, null)
      is_scoped_mode                          = try(autoscaler_settings.value.is_scoped_mode, null)
      node_templates_partial_matching_enabled = try(autoscaler_settings.value.node_templates_partial_matching_enabled, null)

      dynamic "unschedulable_pods" {
        for_each = try([autoscaler_settings.value.unschedulable_pods], [])

        content {
          enabled = try(unschedulable_pods.value.enabled, null)

          dynamic "pod_pinner" {
            for_each = try([unschedulable_pods.value.pod_pinner], [])

            content {
              enabled = try(pod_pinner.value.enabled, null)
            }
          }
        }
      }

      dynamic "cluster_limits" {
        for_each = try([autoscaler_settings.value.cluster_limits], [])

        content {
          enabled = try(cluster_limits.value.enabled, null)


          dynamic "cpu" {
            for_each = try([cluster_limits.value.cpu], [])

            content {
              min_cores = try(cpu.value.min_cores, null)
              max_cores = try(cpu.value.max_cores, null)
            }
          }
        }
      }

      dynamic "node_downscaler" {
        for_each = try([autoscaler_settings.value.node_downscaler], [])

        content {
          enabled = try(node_downscaler.value.enabled, null)

          dynamic "empty_nodes" {
            for_each = try([node_downscaler.value.empty_nodes], [])

            content {
              enabled       = try(empty_nodes.value.enabled, null)
              delay_seconds = try(empty_nodes.value.delay_seconds, null)
            }
          }

          dynamic "evictor" {
            for_each = try([node_downscaler.value.evictor], [])

            content {
              enabled                                = try(evictor.value.enabled, null)
              dry_run                                = try(evictor.value.dry_run, null)
              aggressive_mode                        = try(evictor.value.aggressive_mode, null)
              scoped_mode                            = try(evictor.value.scoped_mode, null)
              cycle_interval                         = try(evictor.value.cycle_interval, null)
              node_grace_period_minutes              = try(evictor.value.node_grace_period_minutes, null)
              pod_eviction_failure_back_off_interval = try(evictor.value.pod_eviction_failure_back_off_interval, null)
              ignore_pod_disruption_budgets          = try(evictor.value.ignore_pod_disruption_budgets, null)
            }
          }
        }
      }
    }
  }
}
