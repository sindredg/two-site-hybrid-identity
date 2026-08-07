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
| 7 | `AzureBastionSubnet` | `azurerm_subnet` | 10.10.2.0/26. Name is mandatory and case-sensitive |
| 8 | Bastion public IP | `azurerm_public_ip` | Standard, static. Required by the dedicated SKUs |
| 9 | Bastion host | `azurerm_bastion_host` | Basic SKU, gated behind `enable_bastion` |
| 10 | Network interface x2 | `azurerm_network_interface` | Static private IPs, no public IP |
| 11 | Windows VM x2 | `azurerm_windows_virtual_machine` | Server 2022, Gen2 |
| 12 | Auto-shutdown x2 | `azurerm_dev_test_global_vm_shutdown_schedule` | Daily, 19:00 W. Europe |

Fifteen resources in state. Everything per-VM is driven from the `locals.vms` map
in `vms.tf`, expanded with `for_each`, so adding a VM is one map entry rather than
five more resources.

Bastion started on the free Developer SKU and moved to Basic after Developer
proved too unreliable to work against. The subnet sits outside the `enable_bastion`
toggle because an empty subnet is free, so turning Bastion off does not churn the
address space. See [decisions](decisions.md) and
[troubleshooting/00-infrastructure.md](troubleshooting/00-infrastructure.md).

Deliberately not built:

| Item | Why not |
|---|---|
| OS disk | An `os_disk` block inside the VM resource, not a resource of its own |
| VM public IPs | Removed once Bastion was in place. Outbound still works via the subnet's default outbound access |
| NSG on `AzureBastionSubnet` | Bastion needs its own eight-rule set, and a partial one breaks the service in ways that look like a VM fault |
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

Open one in a browser, choose Bastion, enter the credentials. Basic SKU supports
concurrent sessions, so more than one machine can be open at once.

---

## 4. Cost

| Item | Rate | Notes |
|---|---:|---|
| `Standard_B2ls_v2` x2 | | Stopped daily by auto-shutdown |
| 127 GB Standard HDD x2 | | Persists while deallocated |
| Bastion Basic SKU | $0.19/hr | Only while `enable_bastion = true` |
| Bastion public IP | ~$0.005/hr | Standard static, exists with the host |
| VM public IPs | $0.00 | None. Removed with the Bastion migration |

Bastion pricing verified against the Azure Retail Prices API, Sweden Central, USD.

**Bastion bills hourly, not monthly.** The $139/month figure quoted for Basic
assumes it runs continuously. Set `enable_bastion = false` and apply when you
finish a session and the meter stops; a few hours of lab work costs pennies. The
`AzureBastionSubnet` is unaffected and free.

**Auto-shutdown does not auto-start.** VMs are started manually each session, so a
forgotten VM cannot burn credit overnight.

`terraform destroy` removes everything. The provider is configured with
`prevent_deletion_if_contains_resources = false` so the resource group goes in one
pass.

---

## 5. Exit criteria

`terraform plan -detailed-exitcode` returns 0 against the deployed environment,
and `terraform output bastion_connect_urls` gives a working session on both VMs.

Next: `01-ad-environment.md`. Problems and fixes from this phase are in
`troubleshooting/`; known gaps are in `risk-and-limitations.md`.
