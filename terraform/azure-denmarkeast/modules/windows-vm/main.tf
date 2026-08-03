locals {
  slug = lower(var.name)
}

resource "azurerm_network_interface" "this" {
  name                = "nic-${local.slug}"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = var.private_ip == null ? "Dynamic" : "Static"
    private_ip_address            = var.private_ip
  }

  tags = var.tags
}

resource "azurerm_windows_virtual_machine" "this" {
  name                  = var.name
  computer_name         = var.name
  location              = var.location
  resource_group_name   = var.resource_group_name
  size                  = var.size
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.this.id]

  os_disk {
    name                 = "osdisk-${local.slug}"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_storage_account_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = "latest"
  }

  tags = var.tags

  lifecycle {
    # "latest" resolves to whatever build Microsoft published most recently.
    # Without this, a plan run weeks later wants to destroy and rebuild working
    # machines because the resolved version moved underneath it.
    ignore_changes = [source_image_reference[0].version]
  }
}

# count rather than for_each: this is an optional singleton, which is the one
# case the decision matrix reserves count for.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "this" {
  count = var.enable_auto_shutdown ? 1 : 0

  virtual_machine_id    = azurerm_windows_virtual_machine.this.id
  location              = var.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone

  notification_settings {
    enabled = false
  }

  tags = var.tags
}
