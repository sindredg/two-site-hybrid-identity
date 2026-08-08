# Phase 7. Windows LAPS, both backends

**Built:** every managed endpoint given its own rotating local administrator
password, stored encrypted, with both storage backends demonstrated side by side.
This is where the two halves of the lab meet: a policy delivered by on-premises
Group Policy puts one machine's secret in Active Directory and the other's in
Entra ID.

> Schema and permissions from CS01, policy through GPMC, retrieval from both AD and
> the Entra admin center. Commands used in this phase:
> [laps.md](../cmd-sheets/laps.md). See also
> [What is Windows LAPS?](https://learn.microsoft.com/windows-server/identity/laps/laps-overview)
> and [Windows LAPS in Microsoft Entra ID](https://learn.microsoft.com/entra/identity/devices/howto-manage-local-admin-passwords).

**What it fixes.** In most estates the built-in local administrator carries the same
password on every machine because it came from an image, which is the most reliable
lateral movement path in Windows: take one machine, dump the hash, walk onto the
rest. LAPS gives each machine its own password, rotated on a schedule and again
after use, readable only by principals holding a specific right.

**Windows LAPS, not legacy LAPS.** The 2015 version was an MSI installed on every
endpoint using `ms-Mcs-AdmPwd` attributes. Windows LAPS is in-box on Server 2019 and
later, uses `msLAPS-*` attributes, supports encryption at rest, and can target Entra
ID. Nothing is installed on any machine in this phase.

Two verifications were captured later, during Phase 8, see section 8. Failures along the
way are in [troubleshooting/07-windows-laps.md](troubleshooting/07-windows-laps.md).

---

## 1. Where each command runs

| Section | Run from |
|---|---|
| 2. Schema extension | CS01 |
| 3. Permissions | CS01 |
| 4. Policy | CS01, through GPMC |
| 5. Applying | CL01 and CL02, elevated |
| 6, 7. Retrieval | CS01, and the Entra admin center |
| 8. Account check | CL01 and CL02 |

**Elevation matters on the clients.** `Invoke-LapsPolicyProcessing` refuses to run
without it, and membership of Administrators is not the same as running elevated.
Both variants of that are in the troubleshooting log.

---

## 2. Extending the schema

LAPS stores passwords on the computer object, and the AD schema has no attributes
for them until they are added. This is the one genuinely irreversible step in the
phase.

```powershell
Update-LapsADSchema -Verbose
```

![Schema update, binding to the schema FSMO](images/phase7/schema-update-start.png)

The preflight confirms domain membership, notes that elevation is not needed because
this is not a domain controller, runs DC locator, and binds specifically to the
**schema FSMO role holder** rather than to any convenient domain controller. Schema
changes have exactly one legitimate target in a forest.

`DcSiteName: HQ-SwedenCentral` and `ClientSiteName: HQ-SwedenCentral` in that output
are the Phase 4 site definitions being consumed by something that had no idea they
were configured.

Each attribute is confirmed separately:

![One of the six attribute prompts](images/phase7/schema-attribute-prompt.png)

Six attributes and one extended right are added:

| Attribute | Holds |
|---|---|
| `msLAPS-PasswordExpirationTime` | When the password is due to rotate |
| `msLAPS-Password` | Plaintext, used only when encryption is off |
| `msLAPS-EncryptedPassword` | The password encrypted to a named principal |
| `msLAPS-EncryptedPasswordHistory` | Previous passwords |
| `msLAPS-EncryptedDSRMPassword` | Directory Services Restore Mode password on a DC |
| `msLAPS-EncryptedDSRMPasswordHistory` | Its history |

The extended right, `ms-LAPS-Encrypted-Password-Attributes`, is a named permission
grantable in an ACL, which makes "can read this computer object" and "can read this
computer's password" two different rights.

**This cannot be undone.** Schema attributes can be deactivated but never removed,
and the change replicates to every domain controller in the forest. It requires
Schema Admins and, in a real environment, a change window.

`schemaUpdateNow` is invoked twice, forcing the domain controller to reload its
schema cache rather than waiting out the five-minute default.

---

## 3. Permissions

Three separate rights, and keeping them separate is the security model.

**Machines write their own password.** `SELF` means the computer account, so CL01
authenticates as `SINDREDG\CL01$` and updates its own object and nothing else. No
service account, no agent holding standing privilege:

```powershell
Set-LapsADComputerSelfPermission -Identity "OU=Workstations,OU=Sync,DC=sindredg,DC=local"
```

![Self-permission granted on the OU](images/phase7/self-permission.png)

**A group reads it.** The first attempt was refused:

![Isolated name rejected](images/phase7/read-permission-isolated-name.png)

```
The 'sg-it-admins' account appears to be an isolated name but is not a well-known
name. Please use a fully qualified name instead
```

A bare name could resolve against the local SAM database, the domain, or a trusted
domain. LAPS refuses to guess, because resolving it wrongly would grant
password-read rights to the wrong principal.

```powershell
Set-LapsADReadPasswordPermission -Identity "OU=Workstations,OU=Sync,DC=sindredg,DC=local" -AllowedPrincipals "SINDREDG\sg-it-admins"
```

![Qualified name accepted](images/phase7/read-permission-qualified.png)

**A group can force rotation**, deliberately separate from reading. That split lets a
helpdesk tier invalidate a password without ever seeing one:

```powershell
Set-LapsADResetPasswordPermission -Identity "OU=Workstations,OU=Sync,DC=sindredg,DC=local" -AllowedPrincipals "SINDREDG\sg-it-admins"
```

```powershell
Find-LapsADExtendedRights -Identity "OU=Workstations,OU=Sync,DC=sindredg,DC=local"
```

![Who holds the extended right](images/phase7/extended-rights-holders.png)

```
{NT AUTHORITY\SYSTEM, SINDREDG\Domain Admins, SINDREDG\sg-it-admins}
```

**Domain Admins appears without having been granted anything**, because it holds
*All Extended Rights* implicitly across the directory. Section 6 shows why it matters
less than it looks.

---

## 4. Policy

Two GPOs differing only in backend, both linked at `OU=Workstations,OU=Sync` and
each filtered to one client. Phase 5 rehearsed exactly this filtering on
`Loopback-Demo`, for this.

```powershell
New-GPO -Name "Workstation-LAPS-AD" -Comment "Phase 7. LAPS backup to Active Directory. CL01 only."
```

![GPO created](images/phase7/new-gpo-laps-ad.png)

```powershell
Set-GPPermission -Name "Workstation-LAPS-EntraID" -TargetName "Authenticated Users" -TargetType Group -PermissionLevel None
```

```powershell
Set-GPPermission -Name "Workstation-LAPS-EntraID" -TargetName "CL02" -TargetType Computer -PermissionLevel GpoApply
```

![Filtering, with the MS16-072 warning](images/phase7/gppermission-filtering.png)

The MS16-072 warning appears again and is benign for the same reason as in Phase 5:
the replacement principal is a computer account, and computer policy is retrieved in
the computer's own security context.

Settings are authored in GPMC under Computer Configuration, Policies, Administrative
Templates, System, LAPS. **That node exists because Phase 5 copied `LAPS.admx` into
the Central Store**, two phases before anything needed it.

![Configure password backup directory](images/phase7/gpme-backup-directory.png)

`Configure password backup directory` is the switch that turns LAPS on at all. Left
Not Configured, nothing else in the node has any effect.

| Setting | `Workstation-LAPS-AD` | `Workstation-LAPS-EntraID` |
|---|---|---|
| Backup directory | Active Directory (2) | Azure Active Directory (1) |
| Password age | 30 days | 30 days |
| Complexity | 4, all character classes | 4 |
| Length | 20 | 20 |
| Encryption enabled | Yes | Not applicable |
| Authorized decryptor | `SINDREDG\sg-it-admins` | Not applicable |
| Post-authentication actions | Reset and log off | Reset and log off |

**A device uses one backend or the other, never both.** That constraint is the reason
two clients exist. The encryption settings are AD-only; the tenant handles encryption
on the Entra side. Everything else is identical, so the backend is the only variable.

`Post-authentication actions` is set to reset and log off. A retrieved password is
invalidated after a 24 hour grace period rather than surviving until the next
scheduled rotation, so a read grants the credential for one session rather than
indefinitely.

```powershell
Get-GPO -Name "Workstation-LAPS-AD"
```

![Version counter confirms where the settings landed](images/phase7/gpo-version-counter.png)

`ComputerVersion` at 6 while `UserVersion` stays at 0 confirms the settings went into
the computer half. Same check as Phase 5.

---

## 5. Applying it

From each client, elevated:

```powershell
gpupdate /force
```

```powershell
Invoke-LapsPolicyProcessing
```

![CL02 receiving its GPO](images/phase7/cl02-gpresult.png)

`Workstation-Baseline`, `Workstation-LAPS-EntraID` and `Default Domain Policy` on
CL02, with the AD variant correctly absent. The filtering works.

**LAPS runs its own cycle every hour**, independent of Group Policy refresh.
`Invoke-LapsPolicyProcessing` only forces it early; an untouched machine picks the
policy up within the hour regardless.

Before the policy arrived, retrieval returned nothing at all:

![Nothing to retrieve yet](images/phase7/password-empty-before-policy.png)

That is the expected state rather than a fault. Schema and permissions create the
fields; only policy causes a machine to fill them.

---

## 6. Retrieval, Active Directory

```powershell
Get-LapsADPassword -Identity CL01
```

![Read as a Domain Admin](images/phase7/decryption-unauthorized.png)

**This is the most important output in the phase, and it is a refusal.**

```
Source              : EncryptedPassword
DecryptionStatus    : Unauthorized
AuthorizedDecryptor : SINDREDG\sg-it-admins
Password            :
```

Run as `SINDREDG\labadmin`, the sole member of Domain Admins. The object comes back.
The distinguished name, the update time and the expiry are all readable. **The
password is not.**

There are two independent gates, and conflating them is the most common LAPS
misunderstanding:

| Gate | Set by | Controls |
|---|---|---|
| Directory ACL | `Set-LapsADReadPasswordPermission` | Who can read the attribute |
| Encryption principal | Authorized decryptor, in the GPO | Who can decrypt its contents |

A Domain Admin passes the first through *All Extended Rights* and fails the second,
because the password was encrypted to `sg-it-admins` and to nothing else. **Forest
administration does not confer decryption.** That is why the encryption principal is
set rather than left at its default of Domain Admins.

---

## 7. Retrieval, Entra ID

CL02 backs up to the tenant, so the same command against it returns nothing:

![No AD password for CL02](images/phase7/cl02-no-ad-password.png)

That is the one-backend-or-the-other rule visible from outside. One command, two
machines, two different correct answers.

The tenant needs the feature enabled first, under Devices, Device settings. The
password then appears under **Local administrator password recovery**:

![CL02 in the Entra admin center](images/phase7/entra-password-recovery.png)

Last rotation and next rotation thirty days apart, matching the password age in the
GPO. The policy came from on-premises Group Policy and the secret landed in the
cloud.

**The same question, answered by two different systems.** On the AD side, access is a
directory ACL plus an encryption principal: fine-grained, auditable with directory
tooling. On the Entra side it is role membership, Cloud Device Administrator or
above: coarser, centrally managed, audited somewhere else entirely.

---

## 8. Which account is actually managed

The administrator account name was left unset, meaning LAPS manages the built-in
administrator. These VMs were built by Terraform with `admin_username = labadmin`,
so it is worth confirming that the account LAPS manages is the account actually in
use rather than a disabled built-in one.

```powershell
Get-LocalUser | Select-Object Name, Enabled, SID
```

![labadmin is RID 500](images/phase7/cl01-localuser-rid500.png)

**`labadmin` ends in `-500`.** Azure renamed the built-in Administrator rather than
creating a second account, so the default behaviour manages exactly the credential
that mattered.

**LAPS targets the built-in account by RID, not by name.** Renaming the built-in
Administrator is a common hardening step and LAPS is deliberately immune to it.
Setting the account name explicitly would have been redundant.

### What this closes

| Machine | Local administrator |
|---|---|
| CL01 | Managed by LAPS, encrypted to `sg-it-admins`, stored in Active Directory |
| CL02 | Managed by LAPS, stored in Entra ID |
| CS01 | **Still the shared Terraform password.** It sits in `CN=Computers`, which no GPO can be linked to |
| DC01 | **Has no local accounts.** Promotion migrates them into the directory |

DC01 is not an oversight. A domain controller has no local user database, which is
why the schema extension added DSRM attributes: on a DC the only local-equivalent
credential is the Directory Services Restore Mode password, and that is the only
thing LAPS can manage there.

CS01 is a real gap, and fixing it means moving the computer object out of
`CN=Computers` into an OU. That is the same container-versus-OU constraint Phase 5
documented. **Phase 8 has since moved it** to `OU=Servers`, which removes the blocker;
the LAPS policy for that OU is not yet applied, so the row above still stands.

### Captured in Phase 8

Two verifications were missing when this phase closed. Both needed an account inside
`sg-it-admins`, and Phase 8 retires that membership from `cdubois` — so they were run
immediately before the change that would have made them impossible. Evidence is in
[08-tiered-administration.md](08-tiered-administration.md) section 3.

**The positive half of the permission test.** The refusal above is the negative half.
Retrieving the same password as `cdubois` — a member of `sg-it-admins`, not a Domain
Admin, and not even elevated — returns `DecryptionStatus: Success`. One succeeds and one
does not, neither explained by how much authority the caller holds, which is what
demonstrates the boundary end to end.

**Rotation.** `Reset-LapsPassword` on CL01 followed by a second read returned a
different password, with `PasswordUpdateTime` and `ExpirationTimestamp` both advanced by
the 30-day window configured here. The age policy is what drives rotation, and this is
not a one-shot.

---

## 9. Exit criteria

| Criterion | Evidence | Status |
|---|---|---|
| Schema extended | Six `msLAPS-*` attributes and the extended right added | Done |
| Machines can write their own password | `SELF` holds WriteProperty on the OU | Done |
| Read and reset granted to a Tier 1 group | `Find-LapsADExtendedRights` lists `sg-it-admins` | Done |
| Two GPOs, filtered per client | `gpresult` on CL02 shows only the Entra variant | Done |
| CL01 password in Active Directory | `Get-LapsADPassword` returns an encrypted object | Done |
| CL02 password in Entra ID | Local administrator password recovery lists CL02 | Done |
| Encryption boundary holds against Domain Admins | `DecryptionStatus: Unauthorized` | Done |
| LAPS manages the real credential | `labadmin` confirmed as RID 500 | Done |
| Decryption succeeds for `sg-it-admins` | `DecryptionStatus: Success` as `cdubois` | Done, in Phase 8 |
| Rotation verified | Password and both timestamps advanced after `Reset-LapsPassword` | Done, in Phase 8 |

---

## Current milestone boundary

[Phase 8](08-tiered-administration.md) continues from here: it splits the single Domain
Admin account into a tiered model and addresses CS01's unmanaged local administrator.
It is **partly built** — the tier structure exists and CS01 has been relocated, but no
logon has been denied and CS01's password is still the shared Terraform one. Until that
work is finished those controls remain explicit residual risk rather than a completed
claim, and everything in this document holds exactly as written.
