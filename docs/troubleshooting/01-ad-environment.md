# Phase 1. Active Directory environment

Walkthrough: [01-ad-environment.md](../01-ad-environment.md).

A rejected password, a service race on first boot, and three bugs in our own
scripts. Two of those share a root cause: trusting state read before a change
instead of re-reading after it.

---

## 1. DSRM password rejected during promotion

**Symptom.** `Install-ADDSForest` failed after prompting for the Directory
Services Restore Mode password:

```
Install-ADDSForest : Verification of prerequisites for Domain Controller promotion
failed. The Directory Services Restore Mode password does not meet the password
complexity requirements of the password policy. Strong passwords require a
combination of uppercase and lowercase letters, numbers, and symbols.
```

![DSRM password rejected](../images/phase1/dsrm-password-rejected.png)

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

---

## 2. Preflight wrongly reported "already a domain controller"

**Symptom.** After the failed promotion, re-running the script did nothing:

```
== Preflight ==
NTDS service present - this machine is already a domain controller.
Get-ADDomain : Unable to find a default server with Active Directory Web Services running.
```

![Preflight false positive, twice](../images/phase1/preflight-false-positive.png)

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

---

## 3. Logon hangs at "Please wait for the Group Policy Client"

**Symptom.** After the post-promotion reboot, logon never completed.

![Group Policy Client hang](../images/phase1/gpclient-hang.png)

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

---

## 4. `-EnableUsers` silently did nothing on a re-run

**Symptom.** `02-ad-structure.ps1` was run a second time with `-EnableUsers`, as
its own closing message instructs. Every object reported `exists`, and all five
users remained `Enabled: False`.

![Second run reports exists](../images/phase1/ad-structure-idempotent.png)

![Users still disabled](../images/phase1/users-disabled.png)

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

---

## 5. `03-prep-sync.ps1` reported BAD SUFFIX for users it had just fixed

**Symptom.** The `-Apply` run contradicted itself. It reported all five UPNs
retargeted, then flagged all five as unchanged:

```
== Retargeting user UPNs ==
  changed alindqvist@sindredg.local -> alindqvist@<tenant>.onmicrosoft.com
  ...
== Sync blockers ==
  BAD SUFFIX    alindqvist still on alindqvist@sindredg.local
  ...
5 issue(s) to resolve before installing Entra Connect.
```

![Contradictory report: changed, then BAD SUFFIX](../images/phase1/prep-sync-apply.png)

**Cause.** Ours. The user collection was fetched with `Get-ADUser` **before** the
retargeting loop. `Set-ADUser` changed the directory, but the objects held in
memory still carried their pre-change `UserPrincipalName`. The blocker check then
filtered that stale collection, so it reported failures the script had itself just
fixed.

Querying the directory directly confirmed the retargeting had worked: all five
users on `@<tenant>.onmicrosoft.com`, and the forest carrying the
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

![Clean re-run after the fix](../images/phase1/prep-sync-clean.png)

**Lesson.** A script that both changes and verifies has to re-read in between, or
it is checking its own assumptions rather than the system. This is the second
appearance of the same root cause in one phase, the first being the `-EnableUsers`
entry above. Both produced confident, wrong output rather than an error, which is
the harder failure mode to notice.


---
