# The HQ network, read rather than managed. This root never changes anything in
# the HQ resource group except the one peering object below, so the dependency
# runs in a single direction: branch knows about HQ, HQ knows nothing about
# branch. That is what keeps the two states from needing each other.
data "azurerm_virtual_network" "hq" {
  name                = var.hq_vnet_name
  resource_group_name = var.hq_resource_group_name
}

resource "azurerm_resource_group" "branch" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "branch" {
  name                = "vnet-branch"
  address_space       = [var.address_space]
  location            = azurerm_resource_group.branch.location
  resource_group_name = azurerm_resource_group.branch.name
  dns_servers         = var.dns_servers
  tags                = var.tags
}

resource "azurerm_subnet" "branch" {
  name                 = "snet-branch"
  resource_group_name  = azurerm_resource_group.branch.name
  virtual_network_name = azurerm_virtual_network.branch.name
  address_prefixes     = [var.subnet_prefix]
}

# No AzureBastionSubnet, no public IP and no Bastion host here on purpose. The
# Basic SKU host in the HQ VNet reaches these machines across the peering.
# Microsoft's SKU table lists "connect to VMs in peered virtual networks" as
# supported on Basic and unsupported only on Developer, so this costs nothing
# extra. A second Bastion would be a second hourly charge for no capability.

resource "azurerm_network_security_group" "branch" {
  name                = "nsg-branch"
  location            = azurerm_resource_group.branch.location
  resource_group_name = azurerm_resource_group.branch.name
  tags                = var.tags

  # Rules live in azurerm_network_security_rule below. Never add inline
  # security_rule blocks here too: the two forms fight each other and produce
  # a permanent diff.
}

# Identical to the HQ rule, and it works unchanged for a reason worth knowing:
# the VirtualNetwork service tag covers peered address space as well as the local
# VNet. That is what lets Bastion in 10.10.2.0/26 reach a client here without a
# rule that names an address, and it is why the peering has to exist before RDP
# works rather than only before domain join works.
resource "azurerm_network_security_rule" "rdp_from_bastion" {
  name                        = "Allow-RDP-From-Bastion"
  resource_group_name         = azurerm_resource_group.branch.name
  network_security_group_name = azurerm_network_security_group.branch.name
  priority                    = 300
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "*"
}

resource "azurerm_subnet_network_security_group_association" "branch" {
  subnet_id                 = azurerm_subnet.branch.id
  network_security_group_id = azurerm_network_security_group.branch.id
}

# Peering is two separate one-way objects. Both must exist or traffic does not
# flow, and each side independently reports Initiated until its partner appears.
# A peering that still reads Initiated after both are applied means one of them
# failed, not that it is still settling.
#
# The regions differ, which makes this global VNet peering. No gateway and no
# extra configuration, but data transfer is billed in both directions.
resource "azurerm_virtual_network_peering" "branch_to_hq" {
  name                      = "peer-branch-to-hq"
  resource_group_name       = azurerm_resource_group.branch.name
  virtual_network_name      = azurerm_virtual_network.branch.name
  remote_virtual_network_id = data.azurerm_virtual_network.hq.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

# The only resource this root creates outside its own resource group. Kept here
# rather than in terraform/azure so that the HQ root needs no knowledge of the
# branch at all. The trade-off: destroying the HQ VNet would take this peering
# with it, and this state would hold a stale reference until the next apply.
resource "azurerm_virtual_network_peering" "hq_to_branch" {
  name                      = "peer-hq-to-branch"
  resource_group_name       = var.hq_resource_group_name
  virtual_network_name      = var.hq_vnet_name
  remote_virtual_network_id = azurerm_virtual_network.branch.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}
