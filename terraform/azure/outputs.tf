output "resource_group_name" {
  description = "The resource group holding the whole lab."
  value       = azurerm_resource_group.main.name
}

output "private_ips" {
  description = "Private IP per VM. All static: DC01 .4, CS01 .5, CL01 .6, CL02 .7. There are no public IPs - access is via Bastion."
  value       = { for name, nic in azurerm_network_interface.vm : name => nic.private_ip_address }
}

output "bastion_connect_urls" {
  description = "Open one in a browser, then choose Bastion and enter the admin credentials. Empty when enable_bastion is false."
  value = var.enable_bastion ? {
    for name, vm in azurerm_windows_virtual_machine.vm :
    name => "https://portal.azure.com/#@${data.azurerm_client_config.current.tenant_id}/resource${vm.id}/connect"
  } : {}
}

output "bastion_status" {
  description = "Whether the paid Bastion host currently exists. Basic SKU bills hourly while it does."
  value       = var.enable_bastion ? "Basic SKU deployed, billing at 0.19 USD/hour. Set enable_bastion = false and re-apply when done." : "Not deployed. Set enable_bastion = true and re-apply to connect."
}

output "effective_dns_servers" {
  description = "What the VNet currently hands to VMs. Empty list means Azure-provided DNS, which cannot resolve your AD domain."
  value       = length(azurerm_virtual_network.main.dns_servers) > 0 ? azurerm_virtual_network.main.dns_servers : ["azure-provided (set dns_servers = [\"10.10.1.4\"] after promoting DC01)"]
}

output "portal_url" {
  description = "Azure portal view of the resource group."
  value       = "https://portal.azure.com/#@/resource/subscriptions/${var.subscription_id}/resourceGroups/${azurerm_resource_group.main.name}/overview"
}
