locals {
  # enable_client is the cost gate. An empty map builds no VMs while leaving the
  # network and the peering in place, so turning the clients back on does not
  # churn the address space.
  active_clients = var.enable_client ? var.clients : {}
}

# No public IPs. Access is via the Bastion host in the HQ resource group, across
# the peering. Outbound internet comes from the subnet's default outbound access,
# which is what Windows Update and the hybrid join need.
module "client" {
  source   = "../modules/windows-vm"
  for_each = local.active_clients

  name                = each.key
  resource_group_name = azurerm_resource_group.branch.name
  location            = azurerm_resource_group.branch.location
  subnet_id           = azurerm_subnet.branch.id
  private_ip          = cidrhost(var.subnet_prefix, each.value.host_index)

  size           = var.client_size
  image_sku      = each.value.image_sku
  admin_username = var.admin_username
  admin_password = var.admin_password

  enable_auto_shutdown   = var.enable_auto_shutdown
  auto_shutdown_time     = var.auto_shutdown_time
  auto_shutdown_timezone = var.auto_shutdown_timezone

  tags = var.tags

  # An ordering dependency with no data flowing through it, which is the one case
  # that justifies depends_on. Without the peering these machines boot pointing at
  # a DNS server they cannot reach, and the symptom arrives much later as a domain
  # join failure rather than as a network fault.
  depends_on = [
    azurerm_virtual_network_peering.branch_to_hq,
    azurerm_virtual_network_peering.hq_to_branch,
  ]
}
