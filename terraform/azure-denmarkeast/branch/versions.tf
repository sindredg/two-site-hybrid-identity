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

# Separate state from terraform/azure so a mistake here cannot touch DC01.

data "azurerm_client_config" "current" {}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
