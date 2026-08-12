# Read, not managed. The dependency runs one way: branch knows about HQ, HQ knows
# nothing about branch, so neither state needs the other.
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

# No Bastion here. The Basic SKU host in the HQ VNet reaches these machines over
# the peering, which Basic supports. A second Bastion would bill for no
# capability.

resource "azurerm_network_security_group" "branch" {
  name                = "nsg-branch"
  location            = azurerm_resource_group.branch.location
  resource_group_name = azurerm_resource_group.branch.name
  tags                = var.tags

  # Rules are separate resources below. Adding inline security_rule blocks here
  # too produces a permanent diff.
}

# The VirtualNetwork tag covers peered address space, which is how Bastion in
# 10.10.2.0/26 reaches a client here. The peering must exist before RDP works.
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

# Two one-way objects. Both must exist or traffic does not flow, and each reads
# Initiated until its partner appears. Different regions, so this is global
# peering: no gateway needed, but transfer is billed both ways.
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

# The only resource this root creates outside its own resource group, so the HQ
# root needs no knowledge of the branch. Destroying the HQ VNet would take this
# peering with it and leave a stale reference here.
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
