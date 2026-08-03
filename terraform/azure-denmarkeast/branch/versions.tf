terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # Pinned to 4.x deliberately, same as the HQ root. azurerm 5.0 changed the
      # default resource_provider_registration from "legacy" to "none", which
      # breaks the auto-shutdown schedules on subscriptions where
      # Microsoft.DevTestLab was never registered.
      version = "~> 4.2"
    }
  }
}

# Separate state from terraform/azure on purpose. This root is the branch site and
# is meant to grow into unrelated work later, so it should never share a plan with
# the domain controller. A mistake here cannot touch DC01.

data "azurerm_client_config" "current" {}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
