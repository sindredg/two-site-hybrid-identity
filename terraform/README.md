# Hybrid Identity Lab — Azure + Terraform

A three-VM Active Directory lab in `swedencentral` for practising hybrid Entra ID:

| VM | Size | vCPU / RAM | Image | Private IP | Role |
|------|-----------------|-----------|--------------------------|------------|------|
| DC01 | Standard_B2ls_v2 | 2 / 4 GB | Server 2022 Core | 10.10.1.4 | Domain controller |
| CS01 | Standard_B2ls_v2 | 2 / 4 GB | Server 2022 Desktop Exp. | 10.10.1.5 | Entra Connect Sync + Cloud Sync agent |
| CL01 | Standard_B2ls_v2 | 2 / 4 GB | Server 2022 Desktop Exp. | 10.10.1.6 | Domain-joined test client |

All three private IPs are static. See the note on dynamic allocation under "Things that will bite you" before adding a fourth VM.

CL01 is **off by default** (`enable_client = false`) so you only pay for two VMs until you need it.

## Files

| File | Contents |
|------|----------|
| `versions.tf` | Terraform + azurerm provider pinning, provider config |
| `variables.tf` | All inputs, with validation |
| `network.tf` | Resource group, VNet, subnet, NSG, RDP rule, subnet association |
| `vms.tf` | The VM map plus public IP / NIC / VM / disk / shutdown schedule per VM |
| `outputs.tf` | Public and private IPs, ready-made `mstsc` commands, portal link |
| `terraform.tfvars` | Your values. Git-ignored — holds your subscription ID and home IP |

Everything in `vms.tf` is driven off one `locals.vms` map, so all five per-VM resources are declared once and expanded with `for_each`. Adding a fourth box is one map entry.

---

## Before you start: the ARM64 problem

Your machine is Windows on ARM, and you have the ARM64 Terraform build:

```
Terraform v1.15.8 on windows_arm64
```

HashiCorp has **never** published a `windows_arm64` build of the azurerm provider — zero of its 401 released versions. `terraform init` therefore fails with:

```
Provider registry.terraform.io/hashicorp/azurerm v4.81.0 does not have a
package available for your current platform, windows_arm64.
```

This is not fixable from the Terraform config. You need a Terraform binary on a platform the provider actually ships for. Two options:

**Option A — x64 Terraform under emulation (simplest).** Windows 11 on ARM runs x64 binaries transparently. Terraform is I/O-bound here, so emulation costs you nothing noticeable.

```powershell
$dst = "$env:LOCALAPPDATA\Terraform-amd64"
New-Item -ItemType Directory -Force $dst | Out-Null
Invoke-WebRequest "https://releases.hashicorp.com/terraform/1.15.8/terraform_1.15.8_windows_amd64.zip" -OutFile "$env:TEMP\tf.zip"
Expand-Archive "$env:TEMP\tf.zip" -DestinationPath $dst -Force
$env:PATH = "$dst;$env:PATH"
terraform version   # should now say windows_amd64
```

That `$env:PATH` line lasts for the current shell only. To make it permanent, put `%LOCALAPPDATA%\Terraform-amd64` ahead of `C:\Program Files\Terraform` in your user PATH.

**Option B — WSL2.** The provider has native `linux_arm64` builds (308 versions), so there is no emulation at all. Costs you a WSL distro with Terraform and the az CLI installed inside it.

Either way, confirm you are no longer on `windows_arm64` before continuing.

---

## Deploy

### 1. Log in and pick the subscription

You are not currently logged in (`az account show` returns *Please run 'az login'*).

```powershell
az login
```

```powershell
az account show --query id -o tsv
```

Put that GUID into `subscription_id` in `terraform.tfvars`, replacing `REPLACE-WITH-YOUR-SUBSCRIPTION-ID`. There is a validation rule on it, so a forgotten placeholder fails immediately with a clear message rather than a confusing Azure API error.

### 2. Set the admin password

It is deliberately not in any file. Set it as an environment variable in the same shell you run Terraform from — this prompts without echoing it or leaving it in shell history:

```bash
read -rsp 'VM admin password: ' TF_VAR_admin_password && export TF_VAR_admin_password && echo
```

Azure requires 12–123 characters with three of: lowercase, uppercase, digit, symbol. This becomes the local admin on all three VMs, and later your Domain Admin password when you promote DC01. Pick something real.

### 3. Confirm the VM sizes exist in Sweden Central

A size that a region does not offer only surfaces at apply time, as a `SkuNotAvailable` 409. Check before you apply:

```bash
az vm list-skus --location swedencentral --resource-type virtualMachines --size Standard_B --output table
```

**Sweden Central offers only the `_v2` B-series.** `Standard_B1ms` and `Standard_B2s` do not exist there — Azure reports them as "Capacity Restrictions", which reads like a transient shortage but is permanent. There is also no 1-vCPU burstable size in the region, so 2 vCPU is the floor.

All three VMs therefore use `Standard_B2ls_v2` (2 vCPU, 4 GB), the cheapest x64 size with usable memory. `Standard_B2als_v2` is the AMD equivalent at the same spec and usually a little cheaper.

Do not use `Standard_B2pls_v2`, `Standard_B2ps_v2` or `Standard_B2pts_v2`. The `p` means Arm64, and the Windows Server x64 images in this config will not boot on them.

### 4. Init, validate, plan

```powershell
terraform init
```

```powershell
terraform validate
```

```powershell
terraform plan -out=tfplan
```

Expect **14 resources** with `enable_client = false`: six shared ones (resource group, VNet, subnet, NSG, NSG rule, subnet-NSG association) plus four per VM (public IP, NIC, VM, shutdown schedule) for DC01 and CS01. The OS disks are part of the VM resources rather than separate ones, so they do not appear as their own entries. Turning on CL01 adds 4 more, for 18.

Read the plan. Then:

```powershell
terraform apply tfplan
```

Roughly 5–10 minutes. `terraform output` then gives you the IPs and ready-made `mstsc` commands.

---

## After the VMs exist

The order here matters, and step 3 is the one people miss.

**1. Promote DC01.** RDP to DC01's public IP. It is Server Core, so you get a command prompt — that is expected, not a broken install.

```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
Install-ADDSForest -DomainName "lab.local" -InstallDNS
```

Use a routable domain name you own if you want to avoid certificate and UPN-suffix pain later; `lab.local` is fine for a throwaway lab but you will have to add a verified UPN suffix in AD before syncing users to Entra.

**2. Wait for the reboot,** then confirm DNS is answering on DC01.

**3. Point the VNet at DC01.** This is the step that silently breaks domain joins if skipped. Azure-provided DNS cannot resolve your AD domain, so CS01 and CL01 will fail to join with a vague "domain not found". Edit `terraform.tfvars`:

```hcl
dns_servers = ["10.10.1.4"]
```

```powershell
terraform apply
```

**4. Reboot CS01 and CL01.** A VNet DNS change is only picked up by a VM when its NIC re-reads DHCP, which in practice means a restart. Verify inside the VM with `ipconfig /all` — you want to see 10.10.1.4 as the DNS server, not 168.63.129.16.

**5. Join CS01 to the domain.**

```powershell
Add-Computer -DomainName "lab.local" -Credential (Get-Credential) -Restart
```

**6. Install Entra Connect Sync on CS01,** then flip `enable_client = true`, re-apply, and use CL01 to test hybrid Entra join and Conditional Access.

---

## Cost control

The auto-shutdown schedule stops all VMs daily at 19:00 W. Europe time. Change it with `auto_shutdown_time` in `terraform.tfvars`.

Two things worth knowing:

- **Auto-shutdown does not auto-start.** You start VMs manually each session. That is the point — it stops a forgotten VM burning credit overnight.
- **Static public IPs are billed even while the VM is deallocated.** Three Standard SKU IPs is a small but nonzero standing charge. Only the compute stops.

To tear everything down:

```powershell
terraform destroy
```

The provider is configured with `prevent_deletion_if_contains_resources = false`, so the resource group goes in one shot.

---

## Things that will bite you

**There are no public IPs and no internet-facing RDP.** Access is via Azure Bastion, Developer SKU — browser-based RDP from the Azure portal. Run `terraform output bastion_connect_urls`, open one, pick **Bastion**, and enter the admin credentials. Two consequences worth knowing:

- **One VM at a time.** The free Developer SKU is shared infrastructure and does not support concurrent connections. Switch between DC01 and CS01 rather than having both open. Once CS01 is domain-joined you can manage DC01 from it with RSAT instead.
- **Outbound internet still works.** The VMs reach Entra ID and Windows Update through the subnet's default outbound access (`defaultOutboundAccess: true`), not through the removed public IPs. If you ever rebuild the VNet, note that Azure is moving new virtual networks to private-by-default, which would require a NAT Gateway to restore outbound.

Upgrading to Basic SKU would cost **$0.19/hour — about $139/month, billed 24/7** with no auto-shutdown, roughly ten times the VM bill. Only worth it if you genuinely need concurrent sessions.

**Never mix dynamic and static private IPs in this subnet.** Azure allocates dynamic addresses starting at the lowest free one, which is `10.10.1.4` — precisely the address DC01 needs. Terraform creates the NICs in parallel, so a dynamic NIC can claim `.4` a fraction of a second before DC01 asks for it, and the apply dies with `PrivateIPAddressIsAllocated`. That is why all three VMs are pinned. If you add a fourth, give it an explicit address in the `locals.vms` map.

**Moving a private IP from one NIC to another takes two applies.** Terraform has no ordering between unrelated NICs, so it will start creating the NIC that wants the address while the NIC currently holding it is still being modified, and Azure rejects the create. Nothing links them, so `depends_on` would be the only fix and it is not worth it for a one-off migration. Just run `terraform apply` again once the releasing NIC has been updated — or use `terraform apply -parallelism=1` to serialise the whole run.

**Your home IP changes.** The NSG allows RDP from `187.14.97.226/32` only — detected from this machine on 2026-08-01. When your ISP rotates it, RDP hangs with no error. Re-detect and re-apply:

```powershell
(Invoke-RestMethod "https://api.ipify.org?format=json").ip
```

**`terraform.tfstate` contains the admin password in plaintext.** That is how Terraform works, not a bug in this config. The `.gitignore` excludes state and `*.tfvars`. If you ever push this to a remote, move state to an Azure Storage backend rather than trusting the ignore file.

**The image `version = "latest"`** resolves to whatever Microsoft published most recently. A `lifecycle { ignore_changes }` block on `source_image_reference[0].version` stops a later plan from wanting to destroy and rebuild working VMs when a new image ships. Remove it only if you want deliberate rebuilds.

**Do not add inline `security_rule` blocks** to `azurerm_network_security_group`. This config uses the standalone `azurerm_network_security_rule` resource; mixing the two forms makes them overwrite each other on every apply and produces a permanent diff.

**The provider is pinned to `~> 4.2`, not 5.x.** azurerm 5.0 shipped on 2026-07-30 and changed the default resource-provider registration from `legacy` to `none`. On a fresh subscription that breaks the auto-shutdown schedules, because `Microsoft.DevTestLab` is rarely registered by default. If you move to 5.x later, either register it manually or set `resource_providers_to_register` in the provider block.

**DC01 has 2 GB of RAM.** That is why it is Server Core — Desktop Experience on 2 GB with AD DS and DNS will thrash. If you later add Certificate Services or anything else to DC01, bump it to `Standard_B2s`.
