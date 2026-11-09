variable "aks_cluster_name" {
  type        = string
  description = "Name of the cluster to be connected to CAST AI."
}

variable "aks_cluster_region" {
  type        = string
  description = "Region of the AKS cluster"
}

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID"
}

variable "castai_api_url" {
  type        = string
  description = "URL of alternative CAST AI API to be used during development or testing"
  default     = "https://api.cast.ai"
}

# Variables required for connecting AKS cluster to CAST AI
variable "castai_api_token" {
  type        = string
  sensitive   = true
  description = "CAST AI API token created in console.cast.ai API Access keys section"
}

variable "autoscaler_settings" {
  type        = any
  description = "Optional Autoscaler policy definitions to override current autoscaler settings"
  default     = null
}

variable "delete_nodes_on_disconnect" {
  type        = bool
  description = "Optionally delete Cast AI created nodes when the cluster is destroyed"
  default     = false
}

variable "resource_group" {
  type = string
}

variable "additional_resource_groups" {
  type    = list(string)
  default = []
}

variable "node_resource_group" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "create_role" {
  type        = bool
  description = "When true (default), the module creates the custom Azure role definition used by CAST AI and assigns it to the CAST AI principal for `resource_group`, `node_resource_group` and `additional_resource_groups`. When false, only the authentication resources (Azure AD application, service principal and secret, or managed identity and federated identity credential) and the CAST AI cluster registration are created; no role definition or role assignment is created, so the required permissions must be granted by other means."
  default     = true
}

variable "http_proxy" {
  type        = string
  description = "Address to use for proxying http requests from CAST AI components running directly on nodes."
  default     = null
}

variable "https_proxy" {
  type        = string
  description = "Address to use for proxying https requests from CAST AI components running directly on nodes."
  default     = null
}

variable "no_proxy" {
  type        = list(string)
  description = "List of addresses to skip proxying requests from CAST AI components running directly on nodes. Used with http_proxy and https_proxy."
  default     = []
}

variable "ca_certs" {
  type        = list(string)
  description = "List of base64-encoded CA certificates to add to the node's trust store."
  default     = []
}

variable "node_configurations" {
  type        = any
  description = "Map of AKS node configurations to create"
  default     = {}
}

variable "default_node_configuration" {
  type        = string
  description = "ID of the default node configuration"
  default     = ""
}

variable "default_node_configuration_name" {
  type        = string
  description = "Name of the default node configuration"
  default     = ""
}

variable "node_templates" {
  type        = any
  description = "Map of node templates to create"
  default     = {}
}

variable "workload_scaling_policies" {
  type        = any
  description = <<-EOT
    Map of workload scaling policies to create (passed through to castai_workload_scaling_policy).

    Apply threshold:
    - Prefer cpu/memory.apply_threshold_strategy (e.g. { type = "DEFAULT_ADAPTIVE" } for Dynamic).
    - Deprecated apply_threshold is only set when apply_threshold_strategy is absent (default 0.1).
    - If both are supplied, strategy wins and apply_threshold is omitted so older providers
      that mark the fields as conflicting do not fail.

    Min/max constraints:
    - Prefer cpu/memory.constraints for new configurations.
    - Each min/max strategy supports a single field — either constant
      (number, MiB for memory / cores for CPU) or percentage_of_original
      (number, percent of the original pod-spec request). Within a single
      min or max strategy only one of constant / percentage_of_original may
      be set.
    - Legacy cpu/memory.min and cpu/memory.max (plain numbers) are deprecated.
    - The module ensures only one style is passed through: if both legacy
      min/max and constraints are supplied for the same resource (cpu or
      memory), constraints takes precedence and the legacy min/max are
      omitted so the provider does not reject the config.

    Resource limits (console Automatic / Semi-automatic map to MULTIPLIER + flags):
    - limit.only_if_original_exist (bool) — only set limits when the workload originally had them.
    - limit.only_if_original_lower (bool) — only raise limits when original limits are lower than
      requests × multiplier.
    - Both flags are optional booleans and may be combined; see provider docs for workload_scaling_policy.

    JVM optimization:
    - jvm.auto_instrument (bool) — when true, JMX exporter is automatically injected
      into pods where a JVM runtime is detected.
    - jvm.memory.optimization (bool) — enables JVM heap-size optimization.
  EOT
  default     = {}
}

variable "workload_custom_metrics_data_sources" {
  type        = any
  description = "Map of workload custom metrics data sources to create"
  default     = {}
}

variable "azuread_owners" {
  description = "A set of object IDs of principals that will be granted ownership of the Azure AD service principal and application. Defaults to current user."
  type        = list(string)
  default     = null
}

variable "authentication_method" {
  description = "Authentication method for CAST AI. Use 'client_secret' for service principal with password, or 'workload_identity' for federated identity credential"
  type        = string
  default     = "workload_identity"

  validation {
    condition     = contains(["client_secret", "workload_identity"], var.authentication_method)
    error_message = "authentication_method must be either 'client_secret' or 'workload_identity'"
  }
}

variable "authentication_method_migration" {
  description = "Controls migration to workload-identity authentication as more secure default. 'prepare' pre-provisions the workload identity resources - but they remain unused until the authentication method is switched. 'keep-secret-auth' keeps the client secret resources (Azure AD application, service principal and password) while authenticating with workload identity. 'none' disables any migration behavior. This variable is used for incremental migration and will be removed in the future."
  type        = string
  default     = "none"

  validation {
    condition     = contains(["prepare", "none", "keep-secret-auth"], var.authentication_method_migration)
    error_message = "authentication_method_migration must be one of 'prepare', 'none' or 'keep-secret-auth'"
  }
}
