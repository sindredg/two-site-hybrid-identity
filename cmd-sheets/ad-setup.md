# Forest and directory setup

Promotion runs on DC01, which is Server Core, so a Bastion session lands on a
command prompt. Everything after promotion is easier from CS01, which has RSAT.

Scripts live in `scripts/ad-bootstrap/` and are idempotent. See
[Phase 1](../docs/01-ad-environment.md).

## Promoting the domain controller, on DC01

```powershell
.\01-promote-dc.ps1
```

The script checks the address matches the one pinned in Terraform, then installs
the role. Promotion prompts for a **Directory Services Restore Mode** password,
which is separate from the administrator password, must satisfy the domain password
policy, and is not recoverable.

```powershell
Install-ADDSForest -DomainName sindredg.local -DomainNetbiosName SINDREDG -InstallDns -DomainMode WinThreshold -ForestMode WinThreshold -Force
```

`-InstallDns` is not optional in practice. A domain controller has to answer the SRV
lookups clients use to find it.

The machine reboots itself and the session drops.

## Confirming the forest

```powershell
Get-ADDomain | Select-Object DNSRoot, NetBIOSName, DomainMode
```

```powershell
Get-ADForest | Select-Object Name, ForestMode, SchemaMaster, DomainNamingMaster
```

```powershell
dcdiag /q
```

`dcdiag /q` printing nothing at all is success. It only reports failures.

```powershell
net share
```

`SYSVOL` and `NETLOGON` both listed means replication came up.

## Building the directory, on CS01

The password is prompted for rather than passed on the command line, so it does not
land in shell history:

```powershell
.\02-ad-structure.ps1 -DomainName sindredg.local -InitialPassword (Read-Host -AsSecureString 'Initial user password')
```

Users are created **disabled** so the sync scope can be reviewed before any account
is usable. Re-run with `-EnableUsers` once confirmed:

```powershell
.\02-ad-structure.ps1 -DomainName sindredg.local -EnableUsers
```

Running it twice changes nothing. That is the closest the PowerShell layer has to
`terraform plan`.

## Preparing for synchronisation

`.local` cannot be verified in Entra, so users created with a `@sindredg.local` UPN
would sync under the tenant default. Fixing it on-premises first is what a real
`.local` migration does.

Report only, nothing changes:

```powershell
.\03-prep-sync.ps1 -UpnSuffix <tenant>.onmicrosoft.com -DomainName sindredg.local
```

Then applied:

```powershell
.\03-prep-sync.ps1 -UpnSuffix <tenant>.onmicrosoft.com -DomainName sindredg.local -Apply
```

## Inspecting what exists

```powershell
Get-ADOrganizationalUnit -Filter * | Select-Object Name, DistinguishedName
```

```powershell
Get-ADUser -Filter * -SearchBase "OU=Users,OU=Sync,DC=sindredg,DC=local" | Select-Object SamAccountName, UserPrincipalName, Enabled
```

```powershell
Get-ADGroup -Filter * -SearchBase "OU=Groups,OU=Sync,DC=sindredg,DC=local" | Select-Object Name, GroupScope
```

```powershell
Get-ADGroupMember -Identity sg-finance | Select-Object Name, objectClass
```

## AD Recycle Bin

Off by default and **irreversible once enabled**. Without it a deleted object is
recoverable only from a system state backup, and this lab has none:

```powershell
Enable-ADOptionalFeature "Recycle Bin Feature" -Scope ForestOrConfigurationSet -Target sindredg.local
```

```powershell
Get-ADOptionalFeature -Filter * | Select-Object Name, EnabledScopes
```
