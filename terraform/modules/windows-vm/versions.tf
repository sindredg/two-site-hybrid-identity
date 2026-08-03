terraform {
  # optional() in the caller's variable contract needs 1.3, moved blocks need
  # 1.1. 1.5 is the floor both roots already declare.
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # Bounded, not pinned. The roots decide the exact version through their
      # lock files; a module that pins hard would fight them on every upgrade.
      version = "~> 4.2"
    }
  }
}
