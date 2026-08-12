variable "subscription_id" {
  description = "Azure subscription to deploy into. The same one as the HQ root. Get it with: az account show --query id -o tsv"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID. Get it with: az account show --query id -o tsv"
  }
}

# Separate region because the Sweden Central trial vCPU quota is fully used by
# DC01 and CS01. Changing it needs three checks, each of which failed a different
# candidate: regional and family vCPU quota, per-region size availability, and
# Microsoft.DevTestLab coverage for auto-shutdown. See docs/decisions.md.
variable "location" {
  description = "Azure region for the branch site. Must differ from the HQ region and must have spare vCPU quota."
  type        = string
  default     = "denmarkeast"
}

variable "resource_group_name" {
  description = "Resource group holding the branch site. Separate from the HQ group so this environment can grow independently."
  type        = string
  default     = "rg-branch-office"
}

variable "address_space" {
  description = "Branch VNet address space. Must not overlap the HQ VNet (10.10.0.0/16) or the peering is rejected."
  type        = string
  default     = "10.20.0.0/16"
}

variable "subnet_prefix" {
  description = "Branch client subnet. Also the value to register in AD Sites and Services for the branch site."
  type        = string
  default     = "10.20.1.0/24"
}

variable "hq_resource_group_name" {
  description = "Resource group of the HQ root, read to find the VNet to peer with. Must match resource_group_name in terraform/azure."
  type        = string
  default     = "rg-hybridid-swedencentral"
}

variable "hq_vnet_name" {
  description = "VNet name in the HQ root, read to find the network to peer with."
  type        = string
  default     = "vnet-hybridid"
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
  description = "Local administrator password. Set it via the TF_VAR_admin_password environment variable so it never lands in a file. Use the same value as the HQ root, since these machines join the same domain."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.admin_password) >= 12 && length(var.admin_password) <= 123
    error_message = "Azure requires a Windows admin password of 12-123 characters, with 3 of: lowercase, uppercase, digit, symbol."
  }
}

variable "client_size" {
  description = "VM size for the clients. Standard_B2ls_v2 matches the HQ machines. The module rejects the Arm64 p variants outright."
  type        = string
  default     = "Standard_B2ls_v2"
}

# Map keys are the VM, Windows computer and AD computer object names. Renaming a
# key replaces the machine rather than renaming it.
variable "clients" {
  description = "Endpoints to build in the branch site. Key is the VM name; host_index is the host number within subnet_prefix (0-3 are reserved by Azure)."
  type = map(object({
    host_index = number
    image_sku  = optional(string, "2022-datacenter-g2")
  }))

  default = {
    # CL01 is hardened against a baseline, CL02 is the control. CL01 uses AD
    # LAPS, CL02 uses Entra LAPS.
    CL01 = { host_index = 4 }
    CL02 = { host_index = 5 }
  }

  validation {
    condition     = alltrue([for c in var.clients : c.host_index >= 4])
    error_message = "Host indexes 0 to 3 are reserved by Azure in every subnet. Start at 4."
  }

  validation {
    condition     = length(distinct([for c in var.clients : c.host_index])) == length(var.clients)
    error_message = "Two clients share a host_index. They would race for the same address and fail the apply with PrivateIPAddressIsAllocated."
  }
}

variable "enable_client" {
  description = "Create CL01 and CL02, the endpoints that hybrid join, Group Policy, security baselines and LAPS target. Set false to keep the network and the peering in place while paying for nothing."
  type        = bool
  default     = true
}

# DC01 already answers across the peering, so these clients never need
# Azure-provided DNS.
variable "dns_servers" {
  description = "VNet DNS servers. DC01 in the HQ VNet, reached over the peering. Without this the clients cannot resolve the domain and will not join."
  type        = list(string)
  default     = ["10.10.1.4"]
}

# Off because Microsoft.DevTestLab does not publish schedules in Denmark East.
# The VM deploys and the schedule then fails with
# LocationNotAvailableForResourceType. Nothing stops these machines, so
# deallocate them by hand after a session.
variable "enable_auto_shutdown" {
  description = "Create daily auto-shutdown schedules. Requires a region where Microsoft.DevTestLab publishes the schedules resource type."
  type        = bool
  default     = false
}

variable "auto_shutdown_time" {
  description = "Daily auto-shutdown time in 24-hour HHMM form. Ignored when enable_auto_shutdown is false."
  type        = string
  default     = "0100"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3])[0-5][0-9]$", var.auto_shutdown_time))
    error_message = "Must be four digits in 24-hour HHMM form, for example 1900."
  }
}

variable "auto_shutdown_timezone" {
  description = "Windows time zone ID used by the shutdown schedule. Central Europe is W. Europe Standard Time, the same zone Sweden uses."
  type        = string
  default     = "W. Europe Standard Time"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    project    = "ad-infrastructure-lab"
    site       = "branch"
    managed_by = "terraform"
  }
}
