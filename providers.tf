# Root-module provider configuration.
#
# This repository is published as a child module, so it ships without provider
# blocks. When applying this directory directly, these blocks are required.

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
