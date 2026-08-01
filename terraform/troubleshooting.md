# Troubleshooting

Every entry here is a failure that actually happened while building this lab, with
the error string kept verbatim so it is searchable.

---

## `does not have a package available for your current platform, windows_arm64`

HashiCorp has never published a `windows_arm64` build of the `azurerm` provider —
0 of its 401 released versions. No config change fixes this.

Run Terraform from WSL2, where `linux_arm64` is supported natively (308 versions),
or use an x64 Terraform build under Windows emulation.

Check which you have with `terraform version` — it prints the platform.

---

## `PrivateIPAddressIsAllocated`

> IP configuration ... is using the private IP address 10.10.1.4 which is already
> allocated to resource ... nic-cs01

Azure assigns **dynamic** private IPs starting at the lowest free address, which is
`10.10.1.4` — the first usable address, since Azure reserves `.0`–`.3`. Terraform
creates NICs in parallel, so a dynamic NIC can claim `.4` moments before the VM you
pinned to it asks for it.

Give every VM in the subnet a static `private_ip`. Never mix dynamic and static
here. See the `locals.vms` map in `vms.tf`.

---

## Same error again, on the fix itself

Moving an address from one NIC to another is racy even when both are static.
Terraform has no ordering between two unrelated NICs, so it starts creating the NIC
that wants the address while the NIC releasing it is still updating.

Run `terraform apply` a second time once the releasing NIC has been updated, or use
`terraform apply -parallelism=1` to serialise the whole run.

---

## NSG rule rename destroys and recreates at the same priority

Renaming a `azurerm_network_security_rule` resource label makes Terraform plan an
unordered destroy of the old address and create of the new one. If both sit at the
same `priority`, whichever runs first wins and the other fails.

Add a `moved` block so Terraform treats it as one object and orders the replacement:

```hcl
moved {
  from = azurerm_network_security_rule.old_name
  to   = azurerm_network_security_rule.new_name
}
```

---

## `SkuNotAvailable` ... "Capacity Restrictions"

> The requested VM size for resource 'Following SKUs have failed for Capacity
> Restrictions: Standard_B1ms' is currently not available in location 'SwedenCentral'

The wording implies a temporary shortage. It is not. **Sweden Central offers only
the `_v2` B-series** — `Standard_B1ms` and `Standard_B2s` do not exist there, and
retrying will never succeed. There is also **no 1-vCPU burstable size** in the
region, so 2 vCPU is the floor.

```bash
az vm list-skus --location swedencentral --resource-type virtualMachines --size Standard_B --output table
```

Avoid `Standard_B2pls_v2`, `B2ps_v2`, `B2pts_v2`. The `p` means **Arm64** — Windows
Server x64 images will not boot on them.

---

## `PublicIPAddressCannotBeDeleted`

> can not be deleted since it is still allocated to resource ... /ipConfigurations/ipconfig1

Removing `public_ip_address_id` from a NIC and destroying the public IP in the same
apply loses the dependency edge that would have ordered them, so Terraform attempts
the delete first.

Detach first, then delete:

```bash
terraform apply -target=azurerm_network_interface.vm
terraform apply
```

---

## `Moved resource instances excluded by targeting`

`-target` is refused while a `moved` block still has an unapplied move, because
Terraform cannot produce a correct plan without both endpoints in scope. Either drop
the `-target`, or add every address the error names.

---

## `admin_password` is ForceNew and lives in state in plaintext

Changing it **forces a new resource** — a mismatched password plans a destroy and
recreate of both VMs, including a promoted domain controller.

Two consequences:

- `terraform.tfstate` is the only durable record of the password. Keep a copy in a
  password manager. The state file is gitignored and must stay that way.
- If a plan ever shows `azurerm_windows_virtual_machine` as `-/+ must be replaced`,
  stop. The password does not match state. Do not approve it.

---

## Bastion connects but you cannot RDP from your own machine

`mstsc.exe` is absent on recent Windows 11 Home ARM64 builds. That is expected, not
a broken install. This lab has no public IPs by design — use the browser-based
Bastion session from the Azure portal:

```bash
terraform output bastion_connect_urls
```

The free Developer SKU allows **one VM connection at a time**.
