# Deliberately narrow. Exposing the whole provider object would make every
# consumer's diff churn whenever azurerm adds a computed attribute.

output "id" {
  description = "Resource ID of the VM. Used to build Bastion connect URLs."
  value       = azurerm_windows_virtual_machine.this.id
}

output "name" {
  description = "VM name, which is also the Windows computer name and the AD computer object name."
  value       = azurerm_windows_virtual_machine.this.name
}

output "private_ip" {
  description = "The address actually assigned, whether it was requested statically or allocated dynamically."
  value       = azurerm_network_interface.this.private_ip_address
}

output "nic_id" {
  description = "Resource ID of the NIC, for callers that need to attach anything else to it."
  value       = azurerm_network_interface.this.id
}
