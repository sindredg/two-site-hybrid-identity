locals {
  # One entry per VM. Everything below is driven off this map, so adding another
  # box is a single block rather than five more resources.
  #
  # This root holds the HQ site only: the domain controller and the connect
  # server. The clients live in terraform/branch, peered to this VNet.
  #
  # Every VM gets a static private_ip on purpose. Azure assigns dynamic
  # addresses starting at the lowest free one, which is 10.10.1.4 - the same
  # address DC01 needs. Terraform builds the NICs in parallel, so a dynamic NIC
  # can win the race and claim .4 before DC01 asks for it, failing the apply
  # with PrivateIPAddressIsAllocated. Give any VM you add here its own address.
  # Sizes are all Standard_B2ls_v2. Sweden Central offers no v1 B-series at all
  # (B1ms and B2s return SkuNotAvailable there) and no 1-vCPU size in any
  # burstable family, so 2 vCPU / 4 GB is the practical floor. Never use the
  # B2pls_v2 / B2ps_v2 / B2pts_v2 variants here - the p means Arm64, and the
  # Windows x64 images below will not boot on them.
  vms = {
    DC01 = {
      size       = "Standard_B2ls_v2"        # 2 vCPU, 4 GB
      image_sku  = "2022-datacenter-core-g2" # Server Core, Gen2
      private_ip = "10.10.1.4"               # .0-.3 are reserved by Azure
      create     = true
    }

    # CS01, Connect Server. Runs Entra Connect Sync and the management tooling
    # alongside it: GPMC, RSAT, Security Compliance Toolkit. Managing the
    # directory from a member server rather than from the domain controller is
    # the habit worth building.
    #
    # Briefly renamed MGMT01 while Entra was out of scope, then reverted. The map
    # key is the VM name, so a rename replaces the VM, its NIC, its disk and its
    # shutdown schedule - not worth it for a name that is accurate again.
    CS01 = {
      size       = "Standard_B2ls_v2"   # 2 vCPU, 4 GB
      image_sku  = "2022-datacenter-g2" # Desktop Experience, Gen2
      private_ip = "10.10.1.5"
      create     = true
    }

    # CL01 and CL02 used to sit here on .6 and .7. They now live in
    # terraform/branch, in a second region and a second resource group, because
    # Sweden Central had no vCPU quota left for them and a free trial cannot ask
    # for more. See docs/decisions.md.
  }

  active_vms = { for name, cfg in local.vms : name => cfg if cfg.create }
}

# No public IPs. Access is via Azure Bastion (see network.tf), so nothing in this
# lab is reachable from the internet. The VMs keep outbound internet through the
# subnet's default outbound access, which is what Windows Update and the Security
# Compliance Toolkit download need - verified with:
#   az network vnet subnet show ... --query defaultOutboundAccess   (-> true)

resource "azurerm_network_interface" "vm" {
  for_each = local.active_vms

  name                = "nic-${lower(each.key)}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = each.value.private_ip == null ? "Dynamic" : "Static"
    private_ip_address            = each.value.private_ip
  }
}

resource "azurerm_windows_virtual_machine" "vm" {
  for_each = local.active_vms

  name                  = each.key
  computer_name         = each.key
  location              = azurerm_resource_group.main.location
  resource_group_name   = azurerm_resource_group.main.name
  size                  = each.value.size
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.vm[each.key].id]
  tags                  = var.tags

  os_disk {
    name                 = "osdisk-${lower(each.key)}"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS" # Standard HDD
    disk_size_gb         = 127
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = each.value.image_sku
    version   = "latest"
  }

  lifecycle {
    # "latest" resolves to a new build whenever Microsoft publishes one.
    # Without this, a later plan wants to destroy and rebuild working VMs.
    ignore_changes = [source_image_reference[0].version]
  }
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "vm" {
  for_each = local.active_vms

  virtual_machine_id    = azurerm_windows_virtual_machine.vm[each.key].id
  location              = azurerm_resource_group.main.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone
  tags                  = var.tags

  notification_settings {
    enabled = false
  }
}
