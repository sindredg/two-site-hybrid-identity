# Azure CLI

Run from the workstation, in WSL.

```bash
az login
```

```bash
az account show
```

## VM power

**Start DC01 first, every session.** Both networks use it for DNS.

```bash
az vm start --resource-group rg-hybridid-swedencentral --name DC01
```

```bash
az vm start --resource-group rg-hybridid-swedencentral --name CS01
```

```bash
az vm start --resource-group rg-branch-office --name CL01
```

```bash
az vm restart --resource-group rg-branch-office --name CL01
```

**Deallocate, do not stop.** A VM stopped from inside Windows still bills. Only
deallocation releases the compute:

```bash
az vm deallocate --resource-group rg-branch-office --name CL01
```

```bash
az vm deallocate --resource-group rg-branch-office --name CL02
```

The branch clients have no auto-shutdown schedule, because Denmark East does not
publish `Microsoft.DevTestLab`. Deallocating them by hand is the only cost control
they have.

## What is running

```bash
az vm list --resource-group rg-branch-office --show-details --output table
```

```bash
az vm list --resource-group rg-hybridid-swedencentral --show-details --output table
```

## What exists

```bash
az resource list --resource-group rg-branch-office --output table
```

```bash
az group list --output table
```

## Networking

```bash
az network vnet peering list --resource-group rg-branch-office --vnet-name vnet-branch --output table
```

```bash
az network vnet peering list --resource-group rg-hybridid-swedencentral --vnet-name vnet-hybridid --output table
```

Both sides must read `Connected`. `Initiated` means the matching object on the
other side is missing or failed.

```bash
az network vnet subnet show --resource-group rg-branch-office --vnet-name vnet-branch --name snet-branch
```

`defaultOutboundAccess: true` is what gives the VMs internet access without a
public IP or NAT gateway. Newer virtual networks do not always get it.

## Checking a region before deploying into it

Three independent things must all be true, and each fails at a different stage.

Quota, where two counters both need room:

```bash
az vm list-usage --location denmarkeast --output table
```

The size, which a free trial restricts per region on top of the core cap:

```bash
az vm list-skus --location denmarkeast --resource-type virtualMachines --size Standard_B2ls --output table
```

A region returning no rows at all usually means the subscription cannot see it.

Auto-shutdown, which is a separate and much shorter region list:

```bash
az provider show --namespace Microsoft.DevTestLab --query "resourceTypes[?resourceType=='schedules'].locations" --output json
```

## Bastion

```bash
az network bastion list --resource-group rg-hybridid-swedencentral --output table
```

The Basic SKU reaches VMs in peered networks, so this one host serves both sites.

## Reading the tenant

Useful for confirming what synced without clicking through the portal.

```bash
az rest --method GET --url "https://graph.microsoft.com/v1.0/devices"
```

```bash
az rest --method GET --url "https://graph.microsoft.com/v1.0/users"
```
