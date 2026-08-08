# Tiered administration

Structure and surveys run on CS01 with RSAT. Deny-logon policy is authored in GPMC.
User Rights Assignment is not registry-backed and has no cmdlet. Recovery runs from the
workstation against the Azure control plane.

See [Phase 8](../docs/08-tiered-administration.md).

> **Sections marked *pending* have not been run yet.** They are the planned commands,
> not captured output. Phase 8 stops after the deny-rights survey.

## Recovery, before anything else

Deny-logon rights are the easiest way to lock every human out of a domain controller.
Prove the escape hatch before you need it.

```bash
az vm run-command invoke -g rg-hybridid-swedencentral -n DC01 --command-id RunPowerShellScript --scripts "whoami"
```

`nt authority\system`. The Azure VM Agent runs the script as the machine itself. No
logon occurs, so no user right can block it.

Confirm the cmdlets the rollback depends on are actually present on a Core DC:

```bash
az vm run-command invoke -g rg-hybridid-swedencentral -n DC01 --command-id RunPowerShellScript --scripts "Get-Module -ListAvailable GroupPolicy | Select-Object Name, Version"
```

```bash
az vm run-command invoke -g rg-hybridid-swedencentral -n DC01 --command-id RunPowerShellScript --scripts "Install-WindowsFeature GPMC"
```

`NoChangeNeeded` means it came in with the AD DS role. The cmdlet is idempotent.

### Rollback

```bash
az vm run-command invoke -g rg-hybridid-swedencentral -n DC01 --command-id RunPowerShellScript --scripts "Import-Module GroupPolicy; Set-GPLink -Name 'Tier0-Logon-Restrictions' -Target 'OU=Domain Controllers,DC=sindredg,DC=local' -LinkEnabled No; gpupdate /force"
```

**`gpupdate /force` is not optional.** Unlinking undoes nothing by itself. The deny
rights are already in the local security database and stay there until a policy refresh
removes them.

Lower-level fallback, needing only the ActiveDirectory module:

```bash
az vm run-command invoke -g rg-hybridid-swedencentral -n DC01 --command-id RunPowerShellScript --scripts "Import-Module ActiveDirectory; Set-ADObject -Identity 'OU=Domain Controllers,DC=sindredg,DC=local' -Replace @{gPLink='<saved string>'}; gpupdate /force"
```

**Never `-Clear gPLink` on the Domain Controllers OU.** It would unlink *Default Domain
Controllers Policy* along with everything else.

## Capturing link state

```powershell
$domainDN = (Get-ADDomain).DistinguishedName
"OU=Domain Controllers,$domainDN", "OU=Workstations,OU=Sync,$domainDN" | ForEach-Object {
    Get-ADObject -Identity $_ -Properties gPLink | Select-Object DistinguishedName, gPLink
} | Format-List
```

Every link on an OU lives in one string attribute. One bracketed block per GPO, then a
flag after the semicolon:

| Flag | Means |
|---|---|
| `0` | Enabled |
| `1` | Disabled |
| `2` | Enforced |
| `3` | Disabled and enforced |

Copy the output off the VM. Restoring is then one `Set-ADObject -Replace`.

## Structure

Scripted in
[`scripts/ad-bootstrap/04-tier-structure.ps1`](../scripts/ad-bootstrap/04-tier-structure.ps1).
The equivalent by hand:

```powershell
New-ADOrganizationalUnit -Name 'Servers' -Path $domainDN -ProtectedFromAccidentalDeletion $false
```

```powershell
New-ADGroup -Name 'sg-tier0-admins' -GroupScope Global -GroupCategory Security -Path "OU=Admin,OU=NoSync,$domainDN" -Description 'Tier 0 administrators - domain controllers only.'
```

```powershell
New-ADUser -Name 't0-admin' -SamAccountName 't0-admin' -UserPrincipalName "t0-admin@sindredg.local" -Path "OU=Tier0,OU=Admin,OU=NoSync,$domainDN" -AccountPassword (Read-Host -AsSecureString 'Password') -Enabled $true -Description 'Tier 0. Domain controllers only.'
```

**`-Enabled $true` is an argument to `New-ADUser` only.** Omit it and the account is
created disabled. It will list correctly and refuse every logon.

```powershell
Move-ADObject -Identity (Get-ADComputer CS01).DistinguishedName -TargetPath "OU=Servers,$domainDN"
```

`CN=Computers` is a container, not an OU. It has no `gPLink` attribute, so no GPO can
target it. The SID and computer password survive a move untouched.

## Surveying existing deny rights

Run this **before** authoring any User Rights Assignment.

```powershell
Get-GPO -All | ForEach-Object {
    [xml]$x = Get-GPOReport -Guid $_.Id -ReportType Xml
    $ura = $x.GPO.Computer.ExtensionData.Extension.UserRightsAssignment | Where-Object { $_.Name -like 'SeDeny*' }
    foreach ($u in $ura) {
        [PSCustomObject]@{ GPO = $x.GPO.Name; Right = $u.Name; Members = ($u.Member.Name.'#text') -join ', ' }
    }
} | Format-Table -AutoSize -Wrap
```

**User Rights Assignment does not merge across GPOs.** The higher-precedence GPO wins
outright and the other's members stop existing. Anything already set has to be carried
forward into the new GPO or it is silently lost.

| Constant | Setting name in GPMC |
|---|---|
| `SeDenyInteractiveLogonRight` | Deny log on locally |
| `SeDenyRemoteInteractiveLogonRight` | Deny log on through Remote Desktop Services |
| `SeDenyNetworkLogonRight` | Deny access to this computer from the network |
| `SeDenyBatchLogonRight` | Deny log on as a batch job |
| `SeDenyServiceLogonRight` | Deny log on as a service |

| Well-known SID | Principal |
|---|---|
| `S-1-5-113` | Local account |
| `S-1-5-114` | Local account and member of Administrators group |

Effective state on a target machine, which is local policy rather than what any one GPO
asked for:

```powershell
secedit /export /cfg C:\Windows\Temp\rights.inf /areas USER_RIGHTS
```

```powershell
Select-String -Path C:\Windows\Temp\rights.inf -Pattern 'SeDeny'
```

## Authoring the deny GPOs, pending

GPMC: **Computer Configuration, Policies, Windows Settings, Security Settings, Local
Policies, User Rights Assignment.** No cmdlet exists. The setting is not
registry-backed, so `PolicyFileEditor` cannot reach it either.

```powershell
New-GPO -Name "Tier0-Logon-Restrictions" -Comment "Phase 8. Denies Tier 1 and Tier 2 accounts interactive and RDP logon to domain controllers."
```

Author unlinked, check with Group Policy Modeling, then link lowest blast radius first:

```powershell
New-GPLink -Name "Tier2-Logon-Restrictions" -Target "OU=Workstations,OU=Sync,$domainDN" -LinkEnabled Yes -Order 1
```

`-Order 1` is highest precedence at that OU. It must outrank the baseline for the rights
they share.

## Local Administrators by policy

GPMC: **Computer Configuration, Preferences, Control Panel Settings, Local Users and
Groups, New, Local Group.**

| Field | Value |
|---|---|
| Group name | `Administrators (built-in)` |
| Action | **Update** |
| Add member | The tier's group, fully qualified |
| Delete all member users | **unticked** |
| Delete all member groups | **unticked** |

**Use `Administrators (built-in)`,** which resolves by well-known SID and survives a
renamed group. **Leave both delete boxes unticked.** They make the policy authoritative
and strip everything else, including `Domain Admins`.

**Preferences, not Restricted Groups.** Restricted Groups' *Members of this group* list
*replaces* membership wholesale, with the same destructive effect but on by default.

```powershell
Get-LocalGroupMember -Group Administrators
```

**Preferences do not revert.** Removing a member from the item stops it being added
again. It does not remove it from a machine that already has it. Name the other tier's
group with the `Remove from this group` action so membership is stated rather than
accumulated, and clean up anything already applied by hand:

```powershell
Remove-LocalGroupMember -Group Administrators -Member 'SINDREDG\sg-it-admins'
```

## Verification, pending

```powershell
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625} -MaxEvents 5 | Format-List TimeCreated, Message
```

Read on the **target** machine, not the domain controller.

| Field | Value | Means |
|---|---|---|
| Logon Type | `2` | Interactive, `runas` |
| Logon Type | `3` | Network, `net use` |
| Logon Type | `10` | RemoteInteractive, RDP |
| Sub Status | `0xC000015B` | **The user has not been granted the requested logon type at this machine** |
| Sub Status | `0xC000006A` | Wrong password |
| Sub Status | `0xC0000072` | Account disabled |

**A 4625 on its own proves nothing.** Only the substatus separates "the credential was
wrong" from "the credential was correct and the machine refused it anyway".

On the domain controller, for the same attempt:

```powershell
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4768} -MaxEvents 20 | Where-Object { $_.Message -match 't0-admin' } | Select-Object TimeCreated, Id
```

**A TGT was still issued.** Deny-logon rights are enforced by the LSA on the target
machine, not by the KDC. Authentication succeeded; authorization is what failed. That
is why tiering is a containment control rather than an authentication control.

Network path, from a machine in another tier:

```powershell
net use \\CL01\C$ /user:SINDREDG\t0-admin *
```

`System error 5` is the expected result.
