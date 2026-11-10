# Provider configuration for this root configuration.
# Credentials come from az login or ARM_* environment variables.

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
