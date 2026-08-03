# Phase 7. Windows LAPS, both backends

> **Status: Pending.** Not yet executed. Written from documented behaviour, to be
> rewritten as a record with screenshots once run.

**Goal:** remove the shared local administrator password, and demonstrate both LAPS
storage backends side by side.

> See [What is Windows LAPS?](https://learn.microsoft.com/windows-server/identity/laps/laps-overview)
> and [Windows LAPS in Microsoft Entra ID](https://learn.microsoft.com/entra/identity/devices/howto-manage-local-admin-passwords).

**Why this matters.** This is where the two halves of the lab meet. The policy is
delivered by on-premises Group Policy, built in Phase 5. One client stores its
secret in Active Directory, the other in Entra ID, which is only possible because
both were hybrid-joined in Phase 4.

It also closes the shared-credential entry in
[risk-and-limitations.md](risk-and-limitations.md), which has been open since
Phase 0.

---

## 1. Two backends, one per client

A device can back its password up to Active Directory **or** Entra ID, never both.
With two clients we do one of each.

| Client | `BackupDirectory` | Stored in | Retrieved with |
|---|---|---|---|
| CL01 | 2 | Active Directory, encrypted | `Get-LapsADPassword -Identity CL01 -AsPlainText` |
| CL02 | 1 | Microsoft Entra ID | Entra admin center, or Graph `deviceLocalCredentials` |

Both policies come from Group Policy. **Intune is not required and is not used.**
Microsoft's guidance is that hybrid-joined devices can be policied by GPO, which is
what makes the Entra backend reachable on a free tenant.

---

## 2. Licensing

| Element | Requirement |
|---|---|
| The LAPS feature itself | Free on all supported Windows platforms |
| Backup to Active Directory | No licence at all |
| Backup to Entra ID | Entra ID **Free**, which every tenant has |
| Intune-delivered policy | Intune Plan 1. Not used here |
| Conditional Access on password retrieval | P1. Out of scope |

---

## 3. Preparing Active Directory

The forest is at Windows2016 functional level with a Server 2022 domain
controller. That is the configuration where AD-side password **encryption** and
**DSRM account management** both work. On a domain below 2016 functional level,
neither is available and passwords can only be stored in clear text protected by
ACLs.

```powershell
Update-LapsADSchema -Verbose
```

One-time, forest-wide, requires Schema Admin. Adds `msLAPS-Password`,
`msLAPS-EncryptedPassword`, `msLAPS-PasswordExpirationTime` and the DSRM
equivalents.

```powershell
Set-LapsADComputerSelfPermission -Identity "OU=Workstations,OU=Sync,DC=sindredg,DC=local"
```

Grants managed devices permission to write their own password. Inheritable, set on
the OU rather than per computer.

---

## 4. Preparing Entra ID

Entra admin center, **Devices**, **Overview**, **Device settings**, set **Enable
Local Administrator Password Solution (LAPS)** to **Yes**.

Retrieval is authorised by role. `Cloud Device Administrator` carries
`device.LocalCredentials.Read.All`, or a custom role can be granted
`microsoft.directory/deviceLocalCredentials/password/read`. Which principal holds
that right is the real security decision here, not whether to turn the feature on.

---

## 5. Policy

The Windows LAPS ADMX templates are **not** copied into the Central Store
automatically. Phase 5 created the store; this phase depends on the templates being
in it.

Two GPOs differing only in `BackupDirectory`, security-filtered to one client each:

| Setting | CL01 | CL02 |
|---|---|---|
| `BackupDirectory` | 2, Active Directory | 1, Entra ID |
| `PasswordAgeDays` | 30 | 30 |
| `PasswordLength` | 20 | 20 |
| `ADPasswordEncryptionEnabled` | Enabled | Not applicable |
| `AdministratorAccountName` | Default built-in | Default built-in |

The built-in account is identified by its well-known RID rather than by name, so
leaving `AdministratorAccountName` unset is correct unless a custom account is
being managed.

---

## 6. Verification

```powershell
Get-LapsADPassword -Identity CL01 -AsPlainText
```

```powershell
Get-MgDeviceLocalCredential -DeviceId <CL02-device-id>
```

| Check | Expected |
|---|---|
| CL01 password | Retrievable from AD, encrypted at rest |
| CL02 password | Visible in the Entra portal under the device |
| The two passwords | Different from each other and from the original shared password |
| Rotation | Expiry time advances after a forced reset |
| Unauthorised retrieval | Denied for a principal without the right |

The last check is the one that proves the feature rather than merely exercising it.

---

## 7. DSRM

DC01 has a Directory Services Restore Mode password set by hand during Phase 1,
which is another shared credential nobody rotates. LAPS can manage it, and this is
the configuration where that works.

---

## 8. Exit criteria

| Criterion | Status |
|---|---|
| Schema extended, permissions granted | Pending |
| LAPS enabled in the tenant | Pending |
| Two GPOs applying, one per backend | Pending |
| Password retrieved from Active Directory for CL01 | Pending |
| Password retrieved from Entra ID for CL02 | Pending |
| Rotation confirmed on both | Pending |
| Shared-credential entry in the risk register closed | Pending |

---

## Next

[Phase 8](08-tiered-administration.md), marked stretch. The lab already tells a
complete story without it.
