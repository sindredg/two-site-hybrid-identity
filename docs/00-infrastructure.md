# Phase 0. Azure infrastructure

Builds the resource group, network and VMs. From `terraform apply` to two VMs
reachable over Bastion, with no manual portal steps and no internet-facing
surface.

Root: `terraform/azure/`. Run from WSL.

---

## 1. What gets built

| # | Resource | Terraform type | Notes |
|---|---|---|---|
| 1 | Resource group | `azurerm_resource_group` | Single blast radius |
| 2 | Virtual network | `azurerm_virtual_network` | 10.10.0.0/16, DNS switchable to the DC |
| 3 | Subnet | `azurerm_subnet` | 10.10.1.0/24 |
| 4 | Network security group | `azurerm_network_security_group` | No inline rules, see below |
| 5 | NSG rule | `azurerm_network_security_rule` | RDP 3389 from `VirtualNetwork` only |
| 6 | NSG association | `azurerm_subnet_network_security_group_association` | Separate resource |
| 7 | Bastion host | `azurerm_bastion_host` | Developer SKU, free, no subnet or public IP required |
| 8 | Network interface x2 | `azurerm_network_interface` | Static private IPs, no public IP |
| 9 | Windows VM x2 | `azurerm_windows_virtual_machine` | Server 2022, Gen2 |
| 10 | Auto-shutdown x2 | `azurerm_dev_test_global_vm_shutdown_schedule` | Daily, 19:00 W. Europe |

Thirteen resources in state. Everything per-VM is driven from the `locals.vms`
map in `vms.tf`, expanded with `for_each`, so adding a VM is one map entry rather
than five more resources.

Deliberately not built:

| Item | Why not |
|---|---|
| OS disk | An `os_disk` block inside the VM resource, not a resource of its own |
| Public IPs | Removed once Bastion was in place. Outbound still works via the subnet's default outbound access |
| `AzureBastionSubnet` | Only the dedicated SKUs need it. Developer SKU takes `virtual_network_id` instead |
| Inline `security_rule` blocks | Mixing inline and standalone rules makes them overwrite each other every apply |

---

## 2. Files

| File | Contents |
|---|---|
| `versions.tf` | Terraform and provider pinning, provider config |
| `variables.tf` | All inputs, with validation |
| `network.tf` | Resource group, VNet, subnet, NSG, rule, association, Bastion |
| `vms.tf` | The VM map, NICs, VMs, disks, shutdown schedules |
| `outputs.tf` | Private IPs, Bastion connect URLs, portal link |
| `terraform.tfvars` | Your values. Gitignored, holds the subscription ID |

The provider is pinned `~> 4.2`, not 5.x. azurerm 5.0 changed the default
resource provider registration from `legacy` to `none`, which breaks the
auto-shutdown schedules on any subscription where `Microsoft.DevTestLab` was
never registered.

---

## 3. Deploy

```bash
cd terraform/azure
az login
```

Put the subscription GUID in `terraform.tfvars`. A validation rule catches a
forgotten placeholder with a readable message rather than an opaque API error.

```bash
az account show --query id -o tsv
```

The admin password is deliberately in no file. Set it in the shell you run
Terraform from:

```bash
read -rsp 'VM admin password: ' TF_VAR_admin_password && export TF_VAR_admin_password && echo
```

Azure requires 12 to 123 characters with three of: lowercase, uppercase, digit,
symbol. This becomes the local admin on every VM, and later the Domain Admin
password once DC01 is promoted. It lives only for that shell session.

```bash
terraform init
terraform validate
terraform plan -out=tfplan
```

Read the plan, then:

```bash
terraform apply tfplan
```

Roughly five to ten minutes.

```bash
terraform output bastion_connect_urls
```

Open one in a browser, choose Bastion, enter the credentials. Developer SKU
supports one VM connection at a time.

---

## 4. Cost

| Item | Rate | Notes |
|---|---:|---|
| `Standard_B2ls_v2` x2 | | Stopped daily by auto-shutdown |
| 127 GB Standard HDD x2 | | Persists while deallocated |
| Bastion Developer SKU | $0.00 | Free. Basic would be $0.19/hr, about $139/month |
| Public IPs | $0.00 | None. Removed with the Bastion migration |

Bastion pricing verified against the Azure Retail Prices API, Sweden Central, USD.

**Auto-shutdown does not auto-start.** VMs are started manually each session,
which is the point: it stops a forgotten VM burning credit overnight.

`terraform destroy` removes everything. The provider is configured with
`prevent_deletion_if_contains_resources = false` so the resource group goes in one
pass.

---

## 5. Exit criteria

`terraform plan -detailed-exitcode` returns 0 against the deployed environment,
and `terraform output bastion_connect_urls` gives a working session on both VMs.

Next: `01-ad-environment.md`. Problems and fixes from this phase are in
`99-troubleshooting.md`; known gaps are in `risk-and-limitations.md`.
