# Group Policy

Run from CS01, which has GPMC and RSAT. These write to the directory and to SYSVOL
rather than to any one machine, so Server Core never needs a session.

See [Phase 5](../docs/05-group-policy.md).

**Sign in as the domain account.** Bastion refuses `SINDREDG\labadmin`, so use
`labadmin@sindredg.local`. A session running as the local account of the same name
fails in ways that name the computer rather than the account.

```powershell
whoami
```

## Current state

```powershell
Get-GPO -All | Select-Object DisplayName, GpoStatus, ModificationTime
```

```powershell
Get-GPInheritance -Target "OU=Workstations,OU=Sync,DC=sindredg,DC=local"
```

`GpoLinks` is what is linked at that OU. `InheritedGpoLinks` is everything that
reaches objects there, including from the domain root.

```powershell
Get-GPOReport -Name "Workstation-Baseline" -ReportType Html -Path C:\report.html
```

## The Central Store

One copy of the ADMX templates in SYSVOL, so every editor sees the same policies.

```powershell
Copy-Item C:\Windows\PolicyDefinitions\* \\sindredg.local\SYSVOL\sindredg.local\Policies\PolicyDefinitions\ -Recurse
```

**Check both file types afterwards.** The template count matching is not proof the
copy worked:

```powershell
Get-ChildItem \\sindredg.local\SYSVOL\sindredg.local\Policies\PolicyDefinitions\*.admx | Measure-Object
```

```powershell
Get-ChildItem \\sindredg.local\SYSVOL\sindredg.local\Policies\PolicyDefinitions\en-US\*.adml | Measure-Object
```

`.admx` defines the policies, `.adml` holds their display names. Templates without
strings leave GPMC unable to name what it is showing.

## Creating and linking

```powershell
New-GPO -Name "Workstation-Baseline" -Comment "Phase 5. Endpoint computer baseline."
```

```powershell
New-GPLink -Name "Workstation-Baseline" -Target "OU=Workstations,OU=Sync,DC=sindredg,DC=local"
```

```powershell
Set-GPLink -Name "Workstation-Baseline" -Target "OU=Workstations,OU=Sync,DC=sindredg,DC=local" -Order 1
```

Lowest link order is applied last and therefore wins.

```powershell
Remove-GPLink -Name "Loopback-Demo" -Target "OU=Workstations,OU=Sync,DC=sindredg,DC=local"
```

Removing a link leaves the GPO in place. `Remove-GPO` deletes both halves of it, the
directory object and the SYSVOL folder.

## Settings

Administrative Template settings are registry values under a `Policies` key:

```powershell
Set-GPRegistryValue -Name "Workstation-Baseline" -Key "HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System" -ValueName "InactivityTimeoutSecs" -Type DWord -Value 900
```

```powershell
Set-GPRegistryValue -Name "User-Standard" -Key "HKCU\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMapKey" -ValueName "https://autologon.microsoftazuread-sso.com" -Type String -Value "1"
```

`HKLM` writes to the computer half, `HKCU` to the user half. The `UserVersion` and
`ComputerVersion` counters in the output confirm which half changed.

Firewall rules are not registry policy, but `NetSecurity` writes into a GPO's store:

```powershell
New-NetFirewallRule -PolicyStore "sindredg.local\Workstation-Baseline" -DisplayName "Allow ICMPv4-In (lab)" -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -RemoteAddress 10.10.1.0/24,10.20.1.0/24 -Action Allow -Profile Domain
```

```powershell
Get-NetFirewallRule -PolicyStore "sindredg.local\Workstation-Baseline"
```

Turn off the half a GPO does not use, so it is not evaluated:

```powershell
(Get-GPO -Name "Workstation-Baseline").GpoStatus = "UserSettingsDisabled"
```

**No cmdlet exists for Group Policy Preferences.** Local group membership, drive
maps and scheduled tasks are XML in SYSVOL plus a client-side extension registered
on the GPO object, and have to be created in GPMC.

## Security filtering

A GPO applies only where the target holds both Read and Apply group policy.

```powershell
Set-GPPermission -Name "Loopback-Demo" -TargetName "Authenticated Users" -TargetType Group -PermissionLevel None
```

```powershell
Set-GPPermission -Name "Loopback-Demo" -TargetName "CL02" -TargetType Computer -PermissionLevel GpoApply
```

```powershell
Get-GPPermission -Name "Loopback-Demo" -All
```

**Filtering to a user group needs one more step.** Since MS16-072 policy is read in
the computer's security context, so `Authenticated Users` or `Domain Computers` must
keep Read on the Delegation tab or the GPO stops applying to everyone.

## Loopback

User policy sourced from the computer's OU instead of the user's.

```powershell
Set-GPRegistryValue -Name "Loopback-Demo" -Key "HKLM\Software\Policies\Microsoft\Windows\System" -ValueName "UserPolicyMode" -Type DWord -Value 1
```

`1` is Merge, where the computer's user settings apply on top of the user's own and
win on conflict. `2` is Replace, where the user's own GPOs are discarded.

## Verification

From the client:

```powershell
gpupdate /force
```

```powershell
gpresult /r /scope:computer
```

```powershell
gpresult /h C:\gpresult.html
```

From CS01, without a session on the target:

```powershell
Get-GPResultantSetOfPolicy -Computer CL01 -ReportType Html -Path C:\rsop-cl01.html
```

That and `gpresult` are logging mode, meaning what already happened. GPMC's Group
Policy Modeling node simulates what would happen, which is the safer order for
anything that could lock an account out.

Evidence that does not depend on Group Policy's own reporting:

```powershell
Get-NetFirewallRule -PolicyStore ActiveStore -DisplayName "Allow ICMPv4-In (lab)" | Select-Object DisplayName, PolicyStoreSource, Enabled
```

```powershell
Get-WinEvent -LogName "Microsoft-Windows-GroupPolicy/Operational" -MaxEvents 20
```

**Remote RSoP needs more than ICMP.** It reaches the target over RPC and WMI, so a
client firewall that only permits ping returns `The RPC server is unavailable`.
Isolate it before opening anything:

```powershell
Test-NetConnection CL01 -Port 135
```

Logging mode also cannot report on a user who has never signed in to that computer.
For a combination that has not happened, use GPMC's Group Policy Modeling node,
which simulates rather than reads.
