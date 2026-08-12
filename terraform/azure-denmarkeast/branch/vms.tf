locals {
  # The cost gate. An empty map builds no VMs while leaving the network and
  # peering in place.
  active_clients = var.enable_client ? var.clients : {}
}

# No public IPs. Access is via the HQ Bastion host over the peering. Outbound
# internet comes from the subnet default outbound access.
module "client" {
  source   = "../../modules/windows-vm"
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

  # Ordering only, no data flowing, which is what justifies depends_on. Without
  # the peering these machines boot pointing at unreachable DNS and the symptom
  # arrives later as a domain join failure.
  depends_on = [
    azurerm_virtual_network_peering.branch_to_hq,
    azurerm_virtual_network_peering.hq_to_branch,
  ]
}
