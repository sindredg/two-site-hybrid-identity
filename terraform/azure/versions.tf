terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # 5.0 changed resource_provider_registration from legacy to none, which
      # breaks auto-shutdown where Microsoft.DevTestLab was never registered.
      version = "~> 4.2"
    }
  }
}

# Supplies the tenant ID for the portal links in outputs.tf. Without it the URLs
# carry an empty tenant segment and can misroute the session.
data "azurerm_client_config" "current" {}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      # Let `terraform destroy` tear the lab down in one shot.
      prevent_deletion_if_contains_resources = false
    }
  }
}
