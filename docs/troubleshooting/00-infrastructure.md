# Phase 0. Azure infrastructure

Walkthrough: [00-infrastructure.md](../00-infrastructure.md).

Terraform ordering races, a region with no v1 B-series, and a Bastion SKU that had to be replaced.

Three separate failures here share one root cause: two operations with no dependency
edge between them, run concurrently. Terraform orders what it can see.

---

## 1. `PrivateIPAddressIsAllocated` - a dynamic NIC took the DC's address

**Symptom.** The first apply died creating the domain controller's NIC:

```
PrivateIPAddressIsAllocated: IP configuration .../nic-dc01/ipConfigurations/ipconfig1
is using the private IP address 10.10.1.4 which is already allocated to resource
.../nic-cs01/ipConfigurations/ipconfig1
```

**Cause.** CS01 and CL01 were on dynamic allocation. Azure hands dynamic requests
the lowest free address, and the lowest free address is `10.10.1.4`, because
Azure reserves `.0` to `.3`. Terraform creates NICs in parallel with nothing
linking them, so CS01 won the race by about a second and took the address DC01
was pinned to.

**Resolution applied.** Static `private_ip` on every VM in `locals.vms`. DC01
`.4`, CS01 `.5`, CL01 `.6`.

**Rule.** Never mix dynamic and static allocation in the same subnet. Any VM
added later needs its own explicit address.

---

## 2. The same error again, on the fix itself

**Symptom.** Identical message on the next apply, but the ordering in the log
tells a different story:

```
azurerm_network_interface.vm["DC01"]: Creating...
azurerm_network_interface.vm["CS01"]: Modifying...
azurerm_network_interface.vm["CS01"]: Modifications complete after 4s
Error: ... 10.10.1.4 which is already allocated to ... nic-cs01
```

DC01's create started *above* CS01's modification completing. That is the tell.

**Cause.** A migration race, not a config error. Moving an address off one NIC
and onto another are two independent operations with no dependency between them,
so Terraform ran them concurrently. CS01 released `.4` four seconds too late.

**Resolution applied.** Re-ran `terraform apply`. Once CS01 held `.5`, the address
was free and DC01's NIC created cleanly.

**Trade-off.** `terraform apply -parallelism=1` would have avoided it in one pass
at the cost of serialising the entire run. For a one-off migration, running twice
is cheaper.

This is a transition cost only. A build from scratch never hits it, because the
three VMs ask for three different addresses.

---

## 3. NSG rule rename collides at the same priority

**Symptom.** Renaming a `azurerm_network_security_rule` resource label plans an
unordered destroy of the old address and create of the new one. Both sat at
`priority = 300`, and two rules cannot share a priority in one NSG.

**Cause.** Different resource addresses means no dependency edge, which means no
ordering. Same failure family as the NIC address migration above.

**Resolution applied.** A `moved` block, so Terraform treats it as one object and
orders the replacement:

```hcl
moved {
  from = azurerm_network_security_rule.rdp_inbound
  to   = azurerm_network_security_rule.rdp_from_bastion
}
```

Safe to delete once applied.

---

## 4. `SkuNotAvailable` - the region has no v1 B-series at all

**Symptom.** Both VMs failed at create:

```
SkuNotAvailable: The requested VM size for resource 'Following SKUs have failed
for Capacity Restrictions: Standard_B1ms' is currently not available in location
'SwedenCentral'.
```

**First reading, wrong.** "Capacity Restrictions" reads as a transient shortage
worth retrying. It is not.

**Cause.** Sweden Central offers only the `_v2` B-series. `Standard_B1ms` and
`Standard_B2s` do not exist in the region, so retrying would never succeed. There
is also no 1-vCPU burstable size, which makes 2 vCPU the floor.

```bash
az vm list-skus --location swedencentral --resource-type virtualMachines --size Standard_B --output table
```

**Resolution applied.** All three VMs on `Standard_B2ls_v2`, 2 vCPU and 4 GB. The
cheapest x64 size in the region with usable memory. Matches CS01's original spec
exactly; DC01 and CL01 gain 2 GB over plan, because nothing smaller exists.

**Trap.** `Standard_B2pls_v2`, `B2ps_v2` and `B2pts_v2` look like cheap 2-vCPU
options in the same list. Verified `CpuArchitectureType: Arm64`. The `p` means
ARM, and the Windows Server x64 images here will not boot on them.

---

## 5. `PublicIPAddressCannotBeDeleted` - delete ran before detach

**Symptom.** Migrating to Bastion, the public IP deletes failed:

```
PublicIPAddressCannotBeDeleted: Public IP address .../pip-dc01 can not be deleted
since it is still allocated to resource .../nic-dc01/ipConfigurations/ipconfig1.
```

**Cause.** Removing `public_ip_address_id` from the NIC and destroying the public
IP in the same apply removes the very reference that would have ordered them.
Terraform went straight for the delete. Third instance of the same pattern.

**Resolution applied.** Two applies, detach first:

```bash
terraform apply -target=azurerm_network_interface.vm
terraform apply
```

---

## 6. `Moved resource instances excluded by targeting`

**Symptom.** `-target` was refused outright:

```
Resource instances in your current state have moved to new addresses in the
latest configuration. Terraform must include those resource instances while
planning in order to ensure a correct result, but your -target=... options do
not fully cover all of those resource instances.
```

**Cause.** The unapplied `moved` block from the NSG rule rename above. Terraform
cannot produce a correct plan without both endpoints in scope.

**Resolution applied.** Dropped the `-target`. The error also names the exact
addresses to add if targeting is genuinely needed.

---

## 7. `admin_password` is ForceNew and stored in state in plaintext

**Not an error hit, a trap identified during review.** Recorded because the
failure mode is expensive.

The provider documents it plainly: *"Changing this forces a new resource to be
created."* Combined with the password living in `terraform.tfstate` as plaintext,
two things follow.

| Consequence | Handling |
|---|---|
| State is the only durable record of the password | Keep a copy in a password manager. State is gitignored and must stay that way |
| A mismatched password plans a destroy and recreate of both VMs | If a plan shows `azurerm_windows_virtual_machine` as `-/+ must be replaced`, stop. Do not approve it |

`sensitive = true` masks display only. It has no effect on what is written to
state. See `risk-and-limitations.md`.

---

## 8. No RDP client on Windows 11 Home ARM64

**Symptom.** `mstsc.exe` absent from both `System32` and `SysWOW64`.

**Cause.** Recent Windows 11 builds have dropped the classic Remote Desktop
Connection client in favour of the Store "Windows App". Expected, not a broken
install.

**Resolution applied.** Azure Bastion, Developer SKU. Browser-based RDP, no client
needed, and it removed the public IPs entirely as a side effect.

```bash
terraform output bastion_connect_urls
```

**Trade-off.** Developer SKU is free but shared, and supports one VM connection at
a time.

**Superseded.** Developer SKU proved too unreliable to work against: mostly
failing to connect, and black-screening then dropping when it did. Everything on
our side checked out, so the shared pool was the only remaining explanation. The
tell was the intermittency, since a config or firewall block fails identically
every time. We moved to Basic, which is dedicated and needs an `AzureBastionSubnet`
plus a Standard public IP.

The cost framing that pushed us to Developer was wrong. Basic bills **hourly** at
$0.19, so the $139/month figure only applies if it runs continuously. The host is
now gated behind `enable_bastion`, so a working session costs pennies and
`enable_bastion = false` plus an apply stops the meter.

