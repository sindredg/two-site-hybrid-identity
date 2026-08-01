terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # Pinned to 4.x deliberately. azurerm 5.0 changed the default
      # resource_provider_registration from "legacy" to "none", which breaks
      # the auto-shutdown schedules on subscriptions where Microsoft.DevTestLab
      # was never registered.
      version = "~> 4.2"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      # Let `terraform destroy` tear the lab down in one shot.
      prevent_deletion_if_contains_resources = false
    }
  }
}
