variable "subscription_id" {
  description = "Azure subscription to deploy into. The same one as the HQ root. Get it with: az account show --query id -o tsv"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID. Get it with: az account show --query id -o tsv"
  }
}

# The branch region exists to work around the Sweden Central vCPU quota, which is
# capped at 4 on a free trial and fully consumed by DC01 and CS01.
#
# Picking a region took three attempts, so check all three of these before
# changing it. Each one failed at a different and later stage than the last.
#
# 1. Quota, two counters and both must have room. Raising only the regional one
#    still leaves the family counter blocking:
#      az vm list-usage --location <region> -o table
#
# 2. The size, which a free trial restricts per region on top of the core cap.
#    Standard_B2ls_v2 is offered in only three regions on this subscription:
#    swedencentral (full), polandcentral and denmarkeast. Germany West Central
#    returned 354 SKUs and not one usable 2 vCPU x64 with 4 GB:
#      az vm list-skus -l <region> --resource-type virtualMachines --size Standard_B2ls -o table
#
# 3. Auto-shutdown, which is a Microsoft.DevTestLab resource on a separate and
#    much shorter region list. See enable_auto_shutdown below.
#
# Denmark East also failed twice on azurerm_virtual_network with "Root object was
# present, but now absent" - the create succeeded and the read-back returned
# nothing. It settled on a later apply. Treat a repeat of that as the region
# being eventually consistent rather than as a config fault.
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

# The whole client roster, typed rather than buried in a locals block, so adding
# a third machine is a tfvars entry rather than a code change.
#
# host_index feeds cidrhost against subnet_prefix, which means the addresses
# follow the subnet if it ever moves. Keep the map keys stable: they are the VM
# names, the Windows computer names and the AD computer objects, and renaming a
# key replaces the machine rather than renaming it.
variable "clients" {
  description = "Endpoints to build in the branch site. Key is the VM name; host_index is the host number within subnet_prefix (0-3 are reserved by Azure)."
  type = map(object({
    host_index = number
    image_sku  = optional(string, "2022-datacenter-g2")
  }))

  default = {
    # Phase 5 hardens CL01 against a security baseline and leaves CL02 as a
    # control, so Policy Analyzer has something to compare. Phase 6 then points
    # each at a different LAPS backend: CL01 to AD, CL02 to Entra ID.
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

# Set from the first apply, unlike the HQ root where this was added only after
# DC01 was promoted. DC01 already exists and answers across the peering, so there
# is no window in which these clients need Azure-provided DNS.
variable "dns_servers" {
  description = "VNet DNS servers. DC01 in the HQ VNet, reached over the peering. Without this the clients cannot resolve the domain and will not join."
  type        = list(string)
  default     = ["10.10.1.4"]
}

# Off in this region, and not by choice. Auto-shutdown is a Microsoft.DevTestLab
# resource, and that provider is published to a fixed region list that Denmark
# East and Poland Central are both absent from. The VM deploys fine and then the
# schedule fails with LocationNotAvailableForResourceType.
#
# Check before turning it on in a new region:
#
#   az provider show -n Microsoft.DevTestLab --query "resourceTypes[?resourceType=='schedules'].locations" -o json
#
# With this false, nothing stops these machines running. Deallocate them by hand
# when you finish a session - stopping from inside Windows still bills, only a
# deallocate does not:
#
#   az vm deallocate --ids $(az vm list -g rg-branch-office --query "[].id" -o tsv)
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
