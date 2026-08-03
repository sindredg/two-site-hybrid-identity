# One Windows VM and the three things that always travel with it: a NIC, an OS
# disk and a shutdown schedule. Everything the lab learned the hard way is
# encoded as a validation rather than a comment, so the next caller cannot
# repeat it.

variable "name" {
  description = "VM name, also used as the Windows computer name and to derive the NIC and disk names."
  type        = string

  validation {
    condition     = length(var.name) <= 15 && can(regex("^[A-Za-z0-9-]+$", var.name))
    error_message = "Windows computer names are limited to 15 characters and may contain only letters, digits and hyphens. Longer names are silently truncated and then fail to match the AD computer object."
  }
}

variable "resource_group_name" {
  description = "Resource group to create the VM, NIC and disk in."
  type        = string
}

variable "location" {
  description = "Azure region. Must be the region the subnet lives in."
  type        = string
}

variable "subnet_id" {
  description = "Subnet to attach the NIC to."
  type        = string
}

variable "private_ip" {
  description = "Static private IP. Leave null for a dynamic address, but only where no other VM in the same apply needs a specific one: Azure hands out the lowest free address, Terraform builds NICs in parallel, and a dynamic NIC can win the race and fail the apply with PrivateIPAddressIsAllocated."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.private_ip == null || can(cidrnetmask("${var.private_ip}/32"))
    error_message = "private_ip must be a valid IPv4 address, or null for dynamic allocation."
  }
}

variable "size" {
  description = "Azure VM size."
  type        = string

  validation {
    condition     = !can(regex("^Standard_[A-Za-z]+[0-9]+p", var.size))
    error_message = "This looks like an Arm64 size (the 'p' after the vCPU count, e.g. B2pls_v2, D2ps_v5). The Windows x64 images this module defaults to will not boot on it. Pick the variant without the p."
  }
}

variable "image_publisher" {
  description = "Marketplace image publisher."
  type        = string
  default     = "MicrosoftWindowsServer"
}

variable "image_offer" {
  description = "Marketplace image offer."
  type        = string
  default     = "WindowsServer"
}

variable "image_sku" {
  description = "Marketplace image SKU. Use a -g2 SKU: Gen2 is required by the v2 and v6 VM families and is what supports Secure Boot and vTPM if they are added later."
  type        = string
  default     = "2022-datacenter-g2"
}

variable "admin_username" {
  description = "Local administrator account. Azure rejects a set of reserved names."
  type        = string

  validation {
    condition     = !contains(["administrator", "admin", "root", "user", "guest"], lower(var.admin_username))
    error_message = "Azure reserves this username. Pick something else, e.g. labadmin."
  }
}

variable "admin_password" {
  description = "Local administrator password. Written to state in plaintext by the provider - azurerm 4.x has no write-only variant of this argument - so treat anyone who can read state as holding this credential. Supply it through TF_VAR_admin_password rather than a file."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.admin_password) >= 12 && length(var.admin_password) <= 123
    error_message = "Azure requires a Windows admin password of 12-123 characters, with 3 of: lowercase, uppercase, digit, symbol."
  }
}

variable "os_disk_size_gb" {
  description = "OS disk size. Must be at least as large as the image."
  type        = number
  default     = 127

  validation {
    condition     = var.os_disk_size_gb >= 127
    error_message = "The Windows Server images are 127 GB. A smaller disk is rejected at create time."
  }
}

variable "os_disk_storage_account_type" {
  description = "OS disk tier. Standard_LRS is a spinning-disk tier and the cheapest option that works."
  type        = string
  default     = "Standard_LRS"

  validation {
    condition     = contains(["Standard_LRS", "StandardSSD_LRS", "Premium_LRS"], var.os_disk_storage_account_type)
    error_message = "Must be one of Standard_LRS, StandardSSD_LRS or Premium_LRS."
  }
}

variable "enable_auto_shutdown" {
  description = "Create a daily auto-shutdown schedule. The single most effective cost control in the lab, so it defaults on."
  type        = bool
  default     = true
}

variable "auto_shutdown_time" {
  description = "Daily auto-shutdown time in 24-hour HHMM form."
  type        = string
  default     = "0100"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3])[0-5][0-9]$", var.auto_shutdown_time))
    error_message = "Must be four digits in 24-hour HHMM form, for example 1900."
  }
}

variable "auto_shutdown_timezone" {
  description = "Windows time zone ID used by the shutdown schedule."
  type        = string
  default     = "W. Europe Standard Time"
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
