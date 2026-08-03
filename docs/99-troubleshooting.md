# Troubleshooting log

Problems hit during the build, their causes, and the fixes. Error strings are
verbatim so they are searchable.

Entries are cross-referenced by name rather than number, because numbers break
every time one is inserted or removed.

The phase walkthroughs describe the path that worked. Everything that went wrong
lives here instead, so the two can be read for different purposes.

| Phase | Theme |
|---|---|
| 0 | Terraform ordering races, and a region with no v1 B-series |
| 1 | Three bugs in our own scripts, two sharing a root cause: trusting state read before a change instead of re-reading after it |
| 2 | A Windows Server default, a correct refusal, and one thing still unexplained |

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

---

## 9. DSRM password rejected during promotion

**Symptom.** `Install-ADDSForest` failed after prompting for the Directory
Services Restore Mode password:

```
Install-ADDSForest : Verification of prerequisites for Domain Controller promotion
failed. The Directory Services Restore Mode password does not meet the password
complexity requirements of the password policy. Strong passwords require a
combination of uppercase and lowercase letters, numbers, and symbols.
```

![DSRM password rejected](images/phase1/dsrm-password-rejected.png)

**Cause.** Five characters. DSRM is a separate credential from the administrator
password and has to satisfy the same policy.

**Resolution applied.** Retried with 12 or more characters mixing all four
character classes.

**Worth knowing.** This fails at the prerequisite check, so nothing is changed and
the retry is free. Also note the three warnings printed above the error are all
benign, in particular "no static IP assigned to the adapter", which **must** be
ignored on an Azure VM: the address is static in the Azure fabric and the guest
has to stay on DHCP to receive it.

---

## 10. Preflight wrongly reported "already a domain controller"

**Symptom.** After the failed promotion, re-running the script did nothing:

```
== Preflight ==
NTDS service present - this machine is already a domain controller.
Get-ADDomain : Unable to find a default server with Active Directory Web Services running.
```

![Preflight false positive, twice](images/phase1/preflight-false-positive.png)

**Cause.** Ours. The guard tested whether the NTDS **service exists**. Installing
the AD DS role registers NTDS in a Stopped and Disabled state long before any
promotion, so the check fired on a plain standalone server and the script exited
before doing the work it exists to protect. `Get-CimInstance Win32_ComputerSystem`
confirmed `DomainRole: 2` with NTDS and ADWS both Stopped and Disabled.

**Resolution applied.** Test `DomainRole` instead, where 4 is a backup DC and 5 is
a primary DC:

```powershell
$role = (Get-CimInstance Win32_ComputerSystem).DomainRole
if ($role -in 4, 5) { ... }
```

**Lesson.** The presence of a service is not evidence the feature is configured. A
guard that fails closed looks identical to success, which is worse than no guard.

---

## 11. Logon hangs at "Please wait for the Group Policy Client"

**Symptom.** After the post-promotion reboot, logon never completed.

![Group Policy Client hang](images/phase1/gpclient-hang.png)

**Cause.** The promotion had succeeded. `DomainRole: 5`, with NTDS, DNS, ADWS,
Netlogon and gpsvc all Running. But `net share` listed only `C$`, `IPC$` and
`ADMIN$`: **SYSVOL and NETLOGON were missing**, so the Group Policy Client was
waiting for policy that had no share to come from.

The DFS Replication log, 40 seconds after boot:

```
The DFS Replication service failed to contact domain controller  to access
configuration information. Replication is stopped. The service will try again
during the next configuration polling cycle, which will occur in 60 minutes.
Error: 160 (One or more arguments are not correct.)
```

The blank domain controller name is the tell. DFSR started before AD DS finished
coming up on the first post-promotion boot, could not determine which DC to ask,
set `SysvolReady = 0`, and Netlogon therefore refused to create the shares. DFSR
would not have retried for an hour.

**Resolution applied.** Restart both, in order. DFSR first so it can read its
configuration with AD now up, then Netlogon so it re-evaluates the flag:

```powershell
Restart-Service DFSR -Force
Restart-Service Netlogon -Force
```

`SysvolReady` flipped to 1 and both shares appeared.

**Prevention.** Auto-shutdown stops the VMs nightly, so every morning is another
cold boot and the same race. DFSR now starts after AD DS rather than alongside it:

```powershell
sc.exe config DFSR start= delayed-auto
```

Verify with `Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\DFSR`, which
should report `Start: 2` and `DelayedAutostart: 1`.

---

## 12. `-EnableUsers` silently did nothing on a re-run

**Symptom.** `02-ad-structure.ps1` was run a second time with `-EnableUsers`, as
its own closing message instructs. Every object reported `exists`, and all five
users remained `Enabled: False`.

![Second run reports exists](images/phase1/ad-structure-idempotent.png)

![Users still disabled](images/phase1/users-disabled.png)

**Cause.** Ours. `-Enabled` existed only as an argument to `New-ADUser`. On a
re-run every user hits the `exists` branch, the create call never happens, and the
switch is ignored. The script printed advice it could not honour.

Group membership in the same loop was already correct, checked separately so
re-runs repair drift. Enabled state had not been given the same treatment.

**Resolution applied.** An enable check parallel to the membership check:

```powershell
if ($EnableUsers) {
    $acct = Get-ADUser -Identity $sam -Properties Enabled
    if (-not $acct.Enabled) {
        Enable-ADAccount -Identity $sam
    }
}
```

Live directory corrected directly:

```powershell
Get-ADUser -Filter * -SearchBase 'OU=Users,OU=Sync,DC=sindredg,DC=local' | Enable-ADAccount
```

**Lesson.** An idempotency guard has to cover every attribute the script claims to
manage, not just whether the object exists. The real test is not "does a second run
error" but "does a second run converge".

---

## 13. `03-prep-sync.ps1` reported BAD SUFFIX for users it had just fixed

**Symptom.** The `-Apply` run contradicted itself. It reported all five UPNs
retargeted, then flagged all five as unchanged:

```
== Retargeting user UPNs ==
  changed alindqvist@sindredg.local -> alindqvist@sindredemitriohotmail.onmicrosoft.com
  ...
== Sync blockers ==
  BAD SUFFIX    alindqvist still on alindqvist@sindredg.local
  ...
5 issue(s) to resolve before installing Entra Connect.
```

![Contradictory report: changed, then BAD SUFFIX](images/phase1/prep-sync-apply.png)

**Cause.** Ours. The user collection was fetched with `Get-ADUser` **before** the
retargeting loop. `Set-ADUser` changed the directory, but the objects held in
memory still carried their pre-change `UserPrincipalName`. The blocker check then
filtered that stale collection, so it reported failures the script had itself just
fixed.

Querying the directory directly confirmed the retargeting had worked: all five
users on `@sindredemitriohotmail.onmicrosoft.com`, and the forest carrying the
alternative suffix.

```powershell
Get-ADUser -Filter * -SearchBase 'OU=Users,OU=Sync,DC=sindredg,DC=local' |
  Select-Object SamAccountName, UserPrincipalName
```

**Resolution applied.** Re-query between changing and verifying:

```powershell
$users = Get-ADUser -Filter * -SearchBase $syncBase -Properties UserPrincipalName, Surname, GivenName, proxyAddresses
```

Re-running the fixed script against the already-correct directory converges
cleanly: suffix `exists`, every user `ok`, no blockers.

![Clean re-run after the fix](images/phase1/prep-sync-clean.png)

**Lesson.** A script that both changes and verifies has to re-read in between, or
it is checking its own assumptions rather than the system. This is the second
appearance of the same root cause in one phase, the first being the `-EnableUsers`
entry above. Both produced confident, wrong output rather than an error, which is
the harder failure mode to notice.


---

## 14. Entra Connect sign-in blocked by Internet Explorer ESC

**Phase 2.** The Entra sign-in step inside the Connect Sync wizard failed to load.

```
Content within this application coming from the website listed below is being
blocked by Internet Explorer Enhanced Security Configuration.
https://login.microsoftonline.com
```

![IE ESC blocking the sign-in](images/phase2/ie-esc-blocked.png)

Then, on the sign-in page itself:

```
We can't sign you in
JavaScript is required to sign in. Your browser either does not support
JavaScript or it is being blocked.
```

![JavaScript is required to sign in](images/phase2/javascript-blocked.png)

**Cause.** The visible error blames JavaScript. The actual cause is **Internet
Explorer Enhanced Security Configuration**, on by default on Windows Server, which
strips scripting from untrusted zones. The Connect Sync wizard uses an embedded
browser control and inherits that policy.

**Resolution applied.** Disabled ESC for Administrators, then relaunched:

```powershell
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}' -Name IsInstalled -Value 0
Stop-Process -Name Explorer -Force
```

**Restarting Explorer is not enough on its own.** The wizard is a separate process
and reads zone settings at launch, so it must be closed and reopened. That detail
cost a round of "the fix did not work".

**Re-enable it afterwards.** Set the value back to `1`. ESC was disabled for an
installer, not permanently, and a sync server is not the place to leave it off.

**Lesson.** The error names the symptom two layers below the cause. Same shape as
the Group Policy Client hang, where the message named `gpsvc` and the cause was
`SysvolReady = 0`.

---

## 15. Connect Sync refuses a Domain Admin as the connector account

**Phase 2.** Supplying an existing Domain Admin on the AD forest account dialog
was rejected outright.

![AD forest account with a Domain Admin](images/phase2/ad-forest-existing-account.png)

```
Using an Enterprise or Domain administrator account for your AD forest account is
not allowed. Let Microsoft Entra Connect Sync create the account for you or
specify a synchronization account with the correct permissions.
```

![Domain admin rejected](images/phase2/domain-admin-rejected.png)

**Cause.** Not a bug. Two credentials were being conflated:

| Credential | Used | Stored |
|---|---|---|
| Enterprise Admin | Once, to create things | Never |
| AD DS connector account | Every 30 minutes, forever | On the sync server |

If the sync server is compromised, a stored Domain Admin credential hands over the
forest. A stored `MSOL_` credential hands over directory read access. Connect Sync
will not let you make that mistake.

**Resolution applied.** Selected **Create new AD account** and supplied the
Enterprise Admin credential there instead. The wizard mints `MSOL_<hash>` with
Replicate Directory Changes and Replicate Directory Changes All, and nothing else.

**Lesson.** The installer enforced least privilege before the lab got round to it.
The same pattern the risk register flags for `labadmin` is what Phase 7 exists to
fix.

---

## 16. UPN suffix shows "Not Added" for a domain that is verified

**Phase 2. Unresolved.** The Microsoft Entra sign-in configuration page reported
both UPN suffixes as unmatched.

![Both suffixes showing Not Added](images/phase2/upn-suffix-not-added.png)

**`sindredg.local` showing Not Added is correct and permanent.** A `.local` suffix
can never be verified in Entra, because ownership is proved with a public DNS TXT
record and `.local` has no public DNS. That is why Phase 1 retargeted the users
onto the onmicrosoft suffix in the first place.

**`sindredemitriohotmail.onmicrosoft.com` showing Not Added is wrong.** Queried
directly against Graph, outside the wizard:

```
sindredemitriohotmail.onmicrosoft.com   Verified: True   Default: True   Initial: True
```

**Cause: unknown.** Refreshing the page did nothing. Re-authenticating did
nothing. The best remaining hypothesis is that the token was obtained while ESC
was blocking JavaScript, but the wizard offers no way to inspect it. Recorded as
unexplained rather than given an invented cause.

**Resolution applied.** Ticked "Continue without matching all UPN suffixes to
verified domains" and proceeded, on the reasoning that the display was wrong
rather than the tenant:

- All five synced users are already on the onmicrosoft suffix
- That domain is verified, per Graph
- The only accounts still on `@sindredg.local` are outside `OU=Sync` and never sync
- The outcome is cheap to verify afterwards and cheap to correct

**Confirmed correct after the fact.** All five users synced with
`@sindredemitriohotmail.onmicrosoft.com` intact. The wizard was displaying
something untrue and nothing else was wrong.

**Lesson.** When a tool disagrees with the system, check the system. Proceeding on
a Graph query rather than a dialog was the right call, and the verification step
afterwards is what made it a safe call rather than a lucky one.