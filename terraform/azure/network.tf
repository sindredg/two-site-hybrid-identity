resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-hybridid"
  address_space       = ["10.10.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_servers         = var.dns_servers
  tags                = var.tags
}

resource "azurerm_subnet" "main" {
  name                 = "snet-lab"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.10.1.0/24"]
}

# The name is not a preference. Azure looks for a subnet called exactly
# AzureBastionSubnet and rejects the Bastion deployment if it is named anything
# else, or is smaller than /26, or contains any other resource.
#
# Kept outside the enable_bastion toggle on purpose: an empty subnet is free, and
# leaving it in place means turning Bastion back on does not churn the address
# space. Never associate the lab NSG with it - Bastion needs its own rule set,
# and a partial one breaks the service in ways that look like a VM fault.
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.10.2.0/26"]
}

resource "azurerm_network_security_group" "main" {
  name                = "nsg-hybridid"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  # Rules live in azurerm_network_security_rule below. Never add inline
  # security_rule blocks here too: the two forms fight each other and produce
  # a permanent diff.
}

# Tells Terraform this is the old Allow-RDP-From-Admin-IP rule under a new label,
# not a second rule. Without it, Terraform plans an unordered destroy of the old
# address and create of the new one - and since both sit at priority 300, doing
# them in the wrong order fails with a priority conflict. Safe to delete once
# this has been applied.
moved {
  from = azurerm_network_security_rule.rdp_inbound
  to   = azurerm_network_security_rule.rdp_from_bastion
}

# RDP is reachable only from inside the VNet, which in practice means only from
# the Bastion host below. Nothing on the internet can reach 3389.
#
# Azure's built-in AllowVnetInBound rule (priority 65000) would already permit
# this, so the rule is strictly redundant. It is here to state the intent
# explicitly and to keep working if a deny rule is ever added below 65000.
resource "azurerm_network_security_rule" "rdp_from_bastion" {
  name                        = "Allow-RDP-From-Bastion"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.main.name
  priority                    = 300
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "*"
}

# Bastion, Basic SKU: dedicated infrastructure rather than the free Developer
# shared pool, which proved too unreliable to work against - mostly failing to
# connect, and black-screening when it did. See the troubleshooting log.
#
# Basic is 0.19 USD/hour in this region. That is ~139 USD if left running for a
# month, but billing is hourly and this whole block is gated behind
# enable_bastion, so a working session costs pennies. Set enable_bastion = false
# and re-apply when you finish for the day.
#
# Unlike Developer, this takes an ip_configuration rather than virtual_network_id,
# and requires both the AzureBastionSubnet above and a Standard static public IP.
resource "azurerm_public_ip" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name                = "pip-bastion"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "main" {
  count = var.enable_bastion ? 1 : 0

  name                = "bastion-hybridid"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Basic"
  tags                = var.tags

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
}

resource "azurerm_subnet_network_security_group_association" "main" {
  subnet_id                 = azurerm_subnet.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}
