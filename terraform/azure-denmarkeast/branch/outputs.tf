output "resource_group_name" {
  description = "The resource group holding the branch site."
  value       = azurerm_resource_group.branch.name
}

output "private_ips" {
  description = "Private IP per client, all static. There are no public IPs - access is via the Bastion host in the HQ resource group, across the peering."
  value       = { for name, vm in module.client : name => vm.private_ip }
}

output "bastion_connect_urls" {
  description = "Open one in a browser, then choose Bastion and enter the admin credentials. The Bastion these route to lives in the HQ resource group, so it must be running: set enable_bastion = true in terraform/azure and apply."
  value = {
    for name, vm in module.client :
    name => "https://portal.azure.com/#@${data.azurerm_client_config.current.tenant_id}/resource${vm.id}/connect"
  }
}

output "peering_verify" {
  description = "Both directions must read Connected. Initiated on either side means its partner is missing or failed, and neither DNS nor domain join will work until both exist."
  value       = "az network vnet peering list -g ${azurerm_resource_group.branch.name} --vnet-name ${azurerm_virtual_network.branch.name} -o table"
}

output "ad_site_subnet" {
  description = "Register this in AD Sites and Services against the branch site, otherwise every client here lands in Default-First-Site-Name and DC locator has nothing to work with."
  value       = var.subnet_prefix
}

output "portal_url" {
  description = "Azure portal view of the branch resource group."
  value       = "https://portal.azure.com/#@/resource/subscriptions/${var.subscription_id}/resourceGroups/${azurerm_resource_group.branch.name}/overview"
}
