# Windows LAPS

Schema, permissions and retrieval run on CS01. Policy processing and diagnostics run
on the client itself, **elevated**.

See [Phase 7](../docs/07-windows-laps.md).

## Schema, once per forest

Irreversible. Requires Schema Admins and runs against the schema FSMO role holder.

```powershell
Update-LapsADSchema -Verbose
```

```powershell
Get-ADObject -SearchBase (Get-ADRootDSE).schemaNamingContext -Filter 'name -like "ms-LAPS*"' | Select-Object Name
```

Six results when complete.

## Permissions, on CS01

Three separate rights. Machines write, one group reads, one group forces rotation.

```powershell
Set-LapsADComputerSelfPermission -Identity "OU=Workstations,OU=Sync,DC=sindredg,DC=local"
```

```powershell
Set-LapsADReadPasswordPermission -Identity "OU=Workstations,OU=Sync,DC=sindredg,DC=local" -AllowedPrincipals "SINDREDG\sg-it-admins"
```

```powershell
Set-LapsADResetPasswordPermission -Identity "OU=Workstations,OU=Sync,DC=sindredg,DC=local" -AllowedPrincipals "SINDREDG\sg-it-admins"
```

**Always fully qualify the principal.** A bare `sg-it-admins` is rejected as an
isolated name, because it could resolve against the local SAM, the domain, or a
trusted domain.

```powershell
Find-LapsADExtendedRights -Identity "OU=Workstations,OU=Sync,DC=sindredg,DC=local"
```

Domain Admins and SYSTEM appear whether granted or not. They hold *All Extended
Rights* implicitly.

## Policy

Authored in GPMC: Computer Configuration, Policies, Administrative Templates,
System, LAPS. Requires `LAPS.admx` in the Central Store.

| Backup directory | Value |
|---|---|
| Disabled | 0 |
| Microsoft Entra ID | 1 |
| Active Directory | 2 |

`Configure password backup directory` is the master switch. Everything else is inert
without it.

For the Entra backend, enable the feature in the tenant first: Entra admin center,
Devices, Device settings.

```powershell
Get-GPO -Name "Workstation-LAPS-AD"
```

`ComputerVersion` above 0 confirms settings landed in the computer half.

## Applying, on the client, elevated

```powershell
gpupdate /force
```

```powershell
Invoke-LapsPolicyProcessing
```

LAPS also runs its own cycle hourly. This only forces it early.

**It does not fetch Group Policy.** It re-reads the policy the machine already holds, so
after changing a GPO it must follow `gpupdate /force` rather than replace it. Run on its
own it will report the old policy and look like the change did not work.

**Elevation, not just membership.** UAC issues administrators a filtered token, so
the cmdlet fails for a user who is in Administrators but not running elevated.

## Retrieval

From CS01, for AD-backed machines:

```powershell
Get-LapsADPassword -Identity CL01
```

```powershell
Get-LapsADPassword -Identity CL01 -AsPlainText
```

| Field | Means |
|---|---|
| `Source: EncryptedPassword` | Stored encrypted |
| `DecryptionStatus: Unauthorized` | You can read the attribute but not decrypt it |
| `AuthorizedDecryptor` | The principal it was encrypted to |

**Empty output carries no information.** It means the same thing whether the machine
has no policy, an Entra-backed policy, or an AD-backed policy that has not run yet.
Check the client's event 10021 instead.

For Entra-backed machines, use the portal: Devices, Local administrator password
recovery.

## Rotation

```powershell
Reset-LapsPassword
```

Run on the client, elevated. Forces a new password immediately.

Post-authentication actions also rotate the password after someone uses it, following
the configured grace period rather than instantly.

## Diagnostics

The event log is the first place to look, not the last.

```powershell
Get-WinEvent -LogName "Microsoft-Windows-LAPS/Operational" -MaxEvents 20 | Select-Object TimeCreated, Id, Message | Format-List
```

| Event | Meaning |
|---|---|
| 10003 / 10004 | Processing started, succeeded |
| **10021** | **The complete effective policy, including its source.** Start here |
| 10005 | Processing failed, with an error code |
| 10015 | Why the password needed updating. Several reasons at once is normal on a first run |
| 10017 | Failed to write the password to Active Directory |
| 10024 | The effective policy is disabled. Either no policy reached the machine, **or** one did with `Configure password backup directory` set to `Disabled`. Check the GPO's dropdown value before assuming the policy is missing |
| 10035 | The encryption principal could not be resolved, and names the value |

```powershell
Get-LapsDiagnostics
```

## Reading the attributes directly

Splits a client-side failure from a read-side one:

```powershell
Get-ADComputer CL01 -Properties "msLAPS-EncryptedPassword", "msLAPS-PasswordExpirationTime" | Format-List Name, "msLAPS-*"
```

Empty means the client never wrote. Populated but unreadable means the encryption
principal or the ACL is wrong.
