variable "subscription_id" {
  description = "Azure subscription to deploy into. Get it with: az account show --query id -o tsv"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID. Get it with: az account show --query id -o tsv"
  }
}

variable "location" {
  description = "Azure region for every resource in the lab."
  type        = string
  default     = "swedencentral"
}

variable "resource_group_name" {
  description = "Name of the single resource group holding the lab."
  type        = string
  default     = "rg-hybridid-swedencentral"
}

variable "admin_username" {
  description = "Local administrator created on every VM. Azure rejects 'administrator' and 'admin'."
  type        = string
  default     = "labadmin"

  validation {
    condition     = !contains(["administrator", "admin", "root", "user", "guest"], lower(var.admin_username))
    error_message = "Azure reserves this username. Pick something else, e.g. labadmin."
  }
}

variable "admin_password" {
  description = "Local administrator password for every VM. Set it via the TF_VAR_admin_password environment variable so it never lands in a file."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.admin_password) >= 12 && length(var.admin_password) <= 123
    error_message = "Azure requires a Windows admin password of 12-123 characters, with 3 of: lowercase, uppercase, digit, symbol."
  }
}

variable "enable_client" {
  description = "Create CL01. Leave false until you are ready to test hybrid Entra join, so you only pay for two VMs."
  type        = bool
  default     = false
}

variable "dns_servers" {
  description = "VNet DNS servers. Empty means Azure-provided DNS. Set to [\"10.10.1.4\"] after you promote DC01, otherwise CS01 and CL01 cannot resolve the domain and will fail to join."
  type        = list(string)
  default     = []
}

variable "auto_shutdown_time" {
  description = "Daily auto-shutdown time in 24-hour HHMM form."
  type        = string
  default     = "1900"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3])[0-5][0-9]$", var.auto_shutdown_time))
    error_message = "Must be four digits in 24-hour HHMM form, for example 1900."
  }
}

variable "auto_shutdown_timezone" {
  description = "Windows time zone ID used by the shutdown schedule. Sweden is W. Europe Standard Time."
  type        = string
  default     = "W. Europe Standard Time"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    project    = "hybrid-identity-lab"
    managed_by = "terraform"
  }
}
