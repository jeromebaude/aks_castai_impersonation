# Tests the `create_role` variable:
#   true (default) - the custom role definition and its assignments are created
#   false          - only the authentication resources are created, no role at all
#
# The role resources are counted/for_each based on the flag, so the assertions
# below check the number of planned instances rather than their content.

mock_provider "azurerm" {
  mock_data "azurerm_kubernetes_cluster" {
    defaults = {
      location        = "eastus"
      fqdn            = "test-cluster.eastus.azmk8s.io"
      oidc_issuer_url = "https://accounts.google.com"
      network_profile = [{
        pod_cidr           = "10.244.0.0/16"
        service_cidr       = "10.0.0.0/16"
        dns_service_ip     = "10.0.0.10"
        docker_bridge_cidr = "172.17.0.1/16"
        load_balancer_sku  = "standard"
        network_plugin     = "azure"
        network_policy     = "azure"
        outbound_type      = "loadBalancer"
      }]
    }
  }

  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/test-cluster-castai-identity"
      principal_id = "66666666-6666-6666-6666-666666666666"
      client_id    = "77777777-7777-7777-7777-777777777777"
    }
  }

  mock_resource "azurerm_federated_identity_credential" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/test-cluster-castai-identity/federatedIdentityCredentials/castai-federation"
    }
  }

  mock_resource "azurerm_role_definition" {
    defaults = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    }
  }
}

mock_provider "azuread" {
  mock_data "azuread_client_config" {
    defaults = {
      object_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}

mock_provider "castai" {
  mock_resource "castai_aks_cluster" {
    defaults = {
      id = "88888888-8888-8888-8888-888888888888"
    }
  }

  mock_resource "castai_node_configuration" {
    defaults = {
      id = "99999999-9999-9999-9999-999999999999"
    }
  }

  mock_data "castai_impersonation_service_account" {
    defaults = {
      id = "system:serviceaccount:castai-agent:castai-agent"
    }
  }
}

variables {
  aks_cluster_name           = "test-cluster"
  aks_cluster_region         = "eastus"
  subscription_id            = "00000000-0000-0000-0000-000000000000"
  tenant_id                  = "11111111-1111-1111-1111-111111111111"
  resource_group             = "test-rg"
  node_resource_group        = "test-node-rg"
  default_node_configuration = "default"
  node_configurations = {
    default = {
      name    = "default"
      subnets = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/test-vnet/subnets/test-subnet"]
    }
  }
}

run "role_created_by_default" {
  command = plan

  assert {
    condition     = var.create_role == true
    error_message = "create_role should default to true"
  }

  assert {
    condition     = length([for r in azurerm_role_definition.castai : r]) == 1
    error_message = "Azure role definition should be created when create_role is not set"
  }

  assert {
    condition     = length([for r in azurerm_role_assignment.castai_resource_group : r]) == 1
    error_message = "Role assignment for the resource group should be created when create_role is not set"
  }

  assert {
    condition     = length([for r in azurerm_role_assignment.castai_node_resource_group : r]) == 1
    error_message = "Role assignment for the node resource group should be created when create_role is not set"
  }
}

run "role_skipped_when_create_role_false" {
  command = plan

  variables {
    create_role                = false
    additional_resource_groups = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/extra-rg"]
  }

  assert {
    condition     = length([for r in azurerm_role_definition.castai : r]) == 0
    error_message = "Azure role definition must not be created when create_role is false"
  }

  assert {
    condition     = length([for r in azurerm_role_assignment.castai_resource_group : r]) == 0
    error_message = "Resource group role assignment must not be created when create_role is false"
  }

  assert {
    condition     = length([for r in azurerm_role_assignment.castai_node_resource_group : r]) == 0
    error_message = "Node resource group role assignment must not be created when create_role is false"
  }

  assert {
    condition     = length([for r in azurerm_role_assignment.castai_additional_resource_groups : r]) == 0
    error_message = "Additional resource group role assignments must not be created when create_role is false"
  }
}

run "credentials_created_when_create_role_false" {
  command = plan

  variables {
    create_role = false
  }

  assert {
    condition     = length([for r in azurerm_user_assigned_identity.this : r]) == 1
    error_message = "Managed identity should still be created when create_role is false"
  }

  assert {
    condition     = length([for r in azurerm_federated_identity_credential.this : r]) == 1
    error_message = "Federated identity credential should still be created when create_role is false"
  }

  assert {
    condition     = castai_aks_cluster.castai_cluster.name == "test-cluster"
    error_message = "The cluster should still be registered with CAST AI when create_role is false"
  }
}

run "additional_resource_groups_assigned_when_enabled" {
  command = plan

  variables {
    additional_resource_groups = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/extra-rg"]
  }

  assert {
    condition     = length([for r in azurerm_role_assignment.castai_additional_resource_groups : r]) == 1
    error_message = "Additional resource groups should get a role assignment when create_role is true"
  }
}
