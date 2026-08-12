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

# Azure requires this exact name, at least a /26, and no NSG association.
# Kept outside enable_bastion so toggling Bastion does not churn the address space.
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

  # Rules are separate resources below. Adding inline security_rule blocks here
  # too produces a permanent diff.
}

# Renamed from rdp_inbound. Without this, both would sit at priority 300 and the
# unordered destroy and create fails on a priority conflict.
moved {
  from = azurerm_network_security_rule.rdp_inbound
  to   = azurerm_network_security_rule.rdp_from_bastion
}

# Redundant against AllowVnetInBound at 65000, which already permits this. Kept to
# state the intent and to still apply if a deny rule is ever added below 65000.
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

# Basic SKU, not Developer: the shared pool was too unreliable to work against.
# Bills hourly while enable_bastion is true. Set it false when finished.
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
