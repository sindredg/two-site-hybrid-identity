# Phase 8. Tiered administration

> **Status: in progress.** Steps 0 to 7 are built and verified below. The enforcement
> half — deny-logon policy, the cross-tier test matrix and retiring `labadmin` — is
> not yet implemented. Section 9 records exactly where the walkthrough stopped.
> Nothing in this document describes a control that has not been run.

**Being built:** an end to the single Domain Admin account used for everything. Phase 7
removed the shared *local* administrator password; this removes the shared *domain*
one, and brings CS01 — the machine Phase 7 could not reach — under LAPS.

> Managed from CS01 using RSAT and GPMC, with the Azure control plane as the recovery
> path. Commands used in this phase: [tiered-admin.md](../cmd-sheets/tiered-admin.md).
> Structure is scripted in
> [`scripts/ad-bootstrap/04-tier-structure.ps1`](../scripts/ad-bootstrap/04-tier-structure.ps1).
> See also [Microsoft's tiered access model](https://learn.microsoft.com/security/privileged-access-workstations/privileged-access-access-model).

**What it fixes.** `labadmin` is currently the Domain Admin, the local administrator on
every machine that LAPS does not yet manage, and the account used for routine work.
Any credential theft anywhere in the lab is immediately a forest compromise. Tiering
exists to break that: a credential that can administer domain controllers must never be
typed into a machine that a lower-privileged attacker could already own.

The rule is one-directional. Higher tiers may reach downward. Nothing reaches up.

| Tier | Machines | Admin account | Group |
|---|---|---|---|
| 0 | DC01 | `t0-admin` | `sg-tier0-admins` |
| 1 | CS01 | `t1-admin` | `sg-it-admins` |
| 2 | CL01, CL02 | `t2-admin` | `sg-helpdesk` |

`sg-it-admins` and `sg-helpdesk` were created in Phase 1 with the descriptions
*"Tier 1 administrators - member servers only"* and *"Tier 2 - denied logon to domain
controllers"*. Those descriptions have been aspirational since. This phase makes them
true.

---

## 1. Where each command runs

| Section | Run from |
|---|---|
| 2. Recovery path | Workstation, in WSL, against the Azure control plane |
| 3. Phase 7 verifications | CS01 as `cdubois`, and CL01 elevated |
| 4. Tier structure | CS01 |
| 5. CS01 relocation | CS01 |
| 6. Deny-rights survey | CS01 |

**Nothing runs on DC01 in the completed sections.** Administering the directory from a
member server with RSAT is the practice this phase exists to enforce, and every
interactive logon on a domain controller leaves a Tier 0 credential in its memory.

---

## 2. The recovery path, proven before anything else

Deny-logon rights are the easiest way in Windows to lock every human out of a domain
controller. Before creating a single object, the escape hatch was tested.

```bash
az vm run-command invoke -g rg-hybridid-swedencentral -n DC01 --command-id RunPowerShellScript --scripts "whoami"
```

![Run-command returns SYSTEM](images/phase8/runcommand-system.png)

**`nt authority\system`.** This does not open a network connection to the VM. The
request goes to Azure Resource Manager, which hands the script to the Azure VM Agent
already running inside Windows. The agent is not authenticating as anybody — it *is*
the machine. User Rights Assignment governs logon types, and no logon occurs here, so
no deny rule authored in this phase can close this door.

**That cuts both ways, and it belongs in the risk register.** Anyone holding
`Virtual Machine Contributor` on this subscription can run SYSTEM code on a domain
controller and therefore owns the forest, without touching Active Directory at all.
The Azure control plane is an unreduced parallel path to Tier 0 sitting above the
entire model built below it. See
[risk-and-limitations.md](risk-and-limitations.md).

A recovery path that has not been tested is a plan, not a path. Two more checks
confirmed the cmdlets it depends on actually exist on a Server Core domain controller:

```bash
az vm run-command invoke -g rg-hybridid-swedencentral -n DC01 --command-id RunPowerShellScript --scripts "Get-Module -ListAvailable GroupPolicy | Select-Object Name, Version"
```

![GroupPolicy module present on DC01](images/phase8/runcommand-grouppolicy-module.png)

![GPMC feature already installed](images/phase8/gpmc-already-present.png)

`Install-WindowsFeature GPMC` returned `NoChangeNeeded`, confirming the feature came in
with the AD DS role rather than needing to be added. Nothing was installed and no
restart was required.

### The estate before any change

```powershell
Get-GPO -All | Select-Object DisplayName
```

![Eight GPOs before Phase 8](images/phase8/gpo-estate-before.png)

Eight GPOs from Phases 5, 6 and 7, plus the two defaults.

### The link state, saved

Group Policy links are not separate objects. Every link on an OU lives in a single
string attribute, `gPLink`, on the OU itself:

```powershell
$domainDN = (Get-ADDomain).DistinguishedName
"OU=Domain Controllers,$domainDN", "OU=Workstations,OU=Sync,$domainDN" | ForEach-Object {
    Get-ADObject -Identity $_ -Properties gPLink | Select-Object DistinguishedName, gPLink
} | Format-List
```

![gPLink captured for both target OUs](images/phase8/gplink-captured.png)

One bracketed block per linked GPO: a GUID, then a flag after the semicolon — `0`
enabled, `1` disabled, `2` enforced, `3` both. Link order and precedence are properties
of *the OU*, not of the GPO, which is why they live here.

`OU=Domain Controllers` holds exactly one link, `{6AC1786C-016F-11D2-945F-00C04fB984F9}`
— the well-known GUID of *Default Domain Controllers Policy*, which carries the rights
that make a domain controller function. `OU=Workstations` holds four, from Phases 5 to 7.

**Both strings were copied off the VM before anything was changed.** Restoring a
mangled link set is then one `Set-ADObject -Replace` rather than a reconstruction from
memory. `-Clear gPLink` is never the answer on the Domain Controllers OU: it would take
the default policy with it.

---

## 3. Closing Phase 7's outstanding verifications

Phase 7 left two checks uncaptured, both needing an account inside `sg-it-admins`. At
this point that is `cdubois` — and Phase 8 removes her admin membership later, because
a *synced* user holding on-premises admin rights is the pattern tiering exists to
break. This was the last window to bank that evidence.

```powershell
Get-ADUser cdubois -Properties Enabled, PasswordExpired, MemberOf |
    Select-Object SamAccountName, Enabled, PasswordExpired, @{n='Groups';e={$_.MemberOf -join '; '}}
```

![cdubois enabled, password not expired, in sg-it-admins](images/phase8/cdubois-account-state.png)

`02-ad-structure.ps1` creates seed users with `-ChangePasswordAtLogon $true` and enables
them only when the script is run with `-EnableUsers`. Both matter here: an account
flagged *must change password at next logon* cannot be used with `runas` at all — it
fails before authentication completes, which looks exactly like a wrong password.

### The positive half of the permission test

```powershell
runas /user:SINDREDG\cdubois powershell.exe
```

```powershell
Get-LapsADPassword -Identity CL01 -AsPlainText
```

![Decryption succeeds for sg-it-admins](images/phase8/decryption-authorized.png)

`DecryptionStatus: Success`, `AuthorizedDecryptor: SINDREDG\sg-it-admins`, from a
session that is **not elevated and not a Domain Admin**. Reading a LAPS password needs
directory rights, not local privilege.

**This is the half Phase 7 was missing.** That phase captured `labadmin` — a Domain
Admin — receiving `DecryptionStatus: Unauthorized` on the same command. On its own a
refusal is ambiguous; it could mean the mechanism is broken. Paired with a
non-privileged account succeeding, it proves something specific: *the encryption
principal is a real boundary, and forest-level privilege does not cross it.*

Two commands, opposite results, neither explained by how much authority the caller
holds.

### Rotation

On CL01, elevated:

```powershell
Reset-LapsPassword
```

![Rotation forced on CL01](images/phase8/laps-rotation-forced.png)

Rotation is performed by the managed machine itself. The client generates the password,
sets it on its own account, encrypts it, and writes it to its own computer object.
Nothing else can do this for it — the domain controller stores a secret it cannot
produce. Normally this fires at the 30-day age limit set in Phase 7; the cmdlet only
forces it early.

Read back from CS01, still as `cdubois`:

![Rotation verified, new password and new timestamps](images/phase8/laps-rotation-verified.png)

| | `PasswordUpdateTime` | `ExpirationTimestamp` |
|---|---|---|
| Before | 8/5/2026 1:04 PM | 9/4/2026 1:04 PM |
| After | **8/8/2026 4:35 AM** | **9/7/2026 4:35 AM** |

The password changed and the 30-day window moved with it, which confirms the age policy
from Phase 7 is what drives rotation rather than anything ad hoc.

**The credentials visible in these screenshots were invalidated by a further rotation
after capture.** Evidence of a control being used, then the control used again to
retire the evidence.

---

## 4. The tier structure

Admin accounts are placed **outside sync scope**. Connect Sync is scoped to `OU=Sync`,
so everything below lands on-premises only.

```powershell
$domainDN = (Get-ADDomain).DistinguishedName
$noSyncDN = "OU=NoSync,$domainDN"

New-ADOrganizationalUnit -Name 'Servers' -Path $domainDN -ProtectedFromAccidentalDeletion $false
New-ADOrganizationalUnit -Name 'Admin'   -Path $noSyncDN  -ProtectedFromAccidentalDeletion $false

$adminDN = "OU=Admin,$noSyncDN"
'Tier0','Tier1','Tier2' | ForEach-Object {
    New-ADOrganizationalUnit -Name $_ -Path $adminDN -ProtectedFromAccidentalDeletion $false
}
```

![Tier OUs created](images/phase8/tier-ous-created.png)

![Twelve OUs after the change](images/phase8/ou-tree-after.png)

**A privileged on-premises account with a cloud object is a second attack path onto the
same credential.** Tier 0 goes further than the others: `sg-tier0-admins` is created in
`OU=Admin,OU=NoSync` rather than beside the other `sg-` groups in `OU=Groups,OU=Sync`,
so Tier 0 has no representation in Entra ID at all — not the group, not its member. The
naming inconsistency is deliberate and is recorded in
[decisions.md](decisions.md).

`OU=Servers` sits at the domain root rather than under `NoSync`, because `NoSync` holds
accounts and this holds computers. A GPO linked there should not inherit anything
written for service accounts.

Three accounts, three separate passwords — three accounts sharing one password would
rebuild the exact problem being removed:

```powershell
New-ADUser -Name 't0-admin' -SamAccountName 't0-admin' -UserPrincipalName "t0-admin@sindredg.local" -Path "OU=Tier0,OU=Admin,OU=NoSync,$domainDN" -AccountPassword (Read-Host -AsSecureString 'Password for t0-admin') -Enabled $true -Description 'Tier 0. Domain controllers only.'
```

**`-Enabled $true` is not optional.** `New-ADUser` creates accounts disabled by default.
Omitting it produces three accounts that exist, list correctly, and refuse every logon —
the same trap the seed users fell into in Phase 1.

![Tier group membership](images/phase8/tier-group-membership.png)

`Domain Admins` now holds two members. That is the precondition for retiring `labadmin`
later: until `t0-admin` has been proven to work, `labadmin` is the only verified way in,
and nothing about it is touched.

**A temporary side effect worth noticing.** `Domain Admins` is placed in the local
Administrators group of every domain-joined machine automatically, so `t0-admin` is
currently a local administrator on CL01 and CL02 as well. That is precisely the
condition this phase removes, and capturing the "before" state is what will make the
"after" mean something.

`cdubois` remains in `sg-it-admins` at this point — correct, because her evidence in
section 3 depended on it.

---

## 5. CS01 out of the Computers container

Phase 7 recorded CS01 as *"Still the shared Terraform password. It sits in
`CN=Computers`, which no GPO can be linked to."*

![CS01 in CN=Computers](images/phase8/cs01-in-computers-container.png)

```powershell
Move-ADObject -Identity (Get-ADComputer CS01).DistinguishedName -TargetPath "OU=Servers,$domainDN"
```

![CS01 in OU=Servers](images/phase8/cs01-moved-to-servers.png)

**Group Policy links only to sites, domains and OUs** — the L, D and OU of LSDOU.
`CN=Computers` is a *container*, a different object class with no `gPLink` attribute at
all. This one move unblocks both the Tier 1 policy and LAPS on CS01, and it is the
literal blocker Phase 7 documented and deferred.

**Nothing about CS01's configuration changed.** The computer's SID and password are
untouched, so domain membership and the Connect Sync service are unaffected. And
`Baseline-MemberServer-2022` is linked to `OU=Workstations`, not anywhere CS01 now sits,
so `OU=Servers` inherits only `Default Domain Policy` — exactly what `CN=Computers`
provided. The relocation and the policy changes are kept as separate steps so that if
something breaks later, it is clear which one did it.

---

## 6. What the estate already denies

User Rights Assignment does **not merge across GPOs**. Two GPOs setting the same right
do not combine their member lists — the higher-precedence GPO wins outright and the
other's entries stop existing. Authoring a deny rule without knowing what already sets
it is how a previous phase's control gets silently reverted.

```powershell
Get-GPO -All | ForEach-Object {
    [xml]$x = Get-GPOReport -Guid $_.Id -ReportType Xml
    $ura = $x.GPO.Computer.ExtensionData.Extension.UserRightsAssignment |
           Where-Object { $_.Name -like 'SeDeny*' }
    foreach ($u in $ura) {
        [PSCustomObject]@{
            GPO     = $x.GPO.Name
            Right   = $u.Name
            Members = ($u.Member.Name.'#text') -join ', '
        }
    }
} | Format-Table -AutoSize -Wrap
```

![One GPO sets deny rights, and it sets two](images/phase8/deny-rights-survey.png)

Across the whole estate, exactly one GPO sets any deny-logon right:

| GPO | Right | Members | SID |
|---|---|---|---|
| `Baseline-MemberServer-2022` | `SeDenyNetworkLogonRight` | Local account and member of Administrators group | `S-1-5-114` |
| `Baseline-MemberServer-2022` | `SeDenyRemoteInteractiveLogonRight` | Local account | `S-1-5-113` |

That second row is the mechanism behind the Phase 6 result — *CL01 stops accepting the
shared local administrator account over Bastion.* It can now be named as a specific
setting rather than described as an outcome.

**Interactive, batch and service denies are set by nothing.** Three of the five rights
this phase needs are collision-free.

### The connector account

```powershell
Get-ADUser -Filter "SamAccountName -like 'MSOL_*'" -Properties MemberOf | Select-Object SamAccountName, @{n='Groups';e={$_.MemberOf -join '; '}}
```

![MSOL connector account holds no group memberships](images/phase8/msol-account-no-groups.png)

The Connect Sync AD DS connector account authenticates to DC01 over the network on
every cycle. It holds no group membership beyond `Domain Users`, so it cannot be caught
by any deny rule targeting a tier group.

---

## 7. Design decisions taken from the survey

Three choices follow from section 6 and are recorded here because a reader will
otherwise read them as oversights.

**Deny network logon is deliberately absent on domain controllers.** A DC is not only a
logon target — it is the SYSVOL file server every domain member reads Group Policy
from, and the LDAP endpoint RSAT on CS01 talks to. Denying network logon there for Tier
1 and Tier 2 would break Group Policy retrieval and RSAT for the accounts that need
them. Microsoft's guidance includes it because Tier 1 and 2 *admin* accounts have no
such need in a production estate. In a four-machine lab where `sg-it-admins` does
directory work from CS01, the cost lands directly on the operator. Interactive and RDP
denies are applied; network is not.

**Denying network logon downward is where the control earns its keep.** A Tier 0
credential that cannot make a network logon to a workstation cannot be replayed from
one. It is safe there precisely because Tier 0 has no legitimate business on a
workstation.

**CL02 will gain two settings it does not have today.** The two colliding rights are
also two of the three tier controls that matter most, so `Tier2-Logon-Restrictions` must
define them and carry the baseline's members forward. That GPO links at
`OU=Workstations`, which holds both clients, while the baseline is security-filtered to
CL01 alone. The alternative — dropping RDP and network denies from the tier model —
would remove the single most valuable control in the phase. *Local accounts may not log
on over RDP or the network* is a tiering control on its own merits, so generalising it
to both clients is a defensible hardening rather than an accident.

**What that costs, stated plainly:** Phase 6's comparison stands as a dated measurement.
From Phase 8 onward CL02 is a control for everything in the baseline *except* those two
user rights. The clean-both-ways option would be splitting `OU=Workstations` into
hardened and control sub-OUs, but that OU's distinguished name appears in Phases 5, 6
and 7 including the LAPS ACLs, and rewriting all of it to preserve a two-setting
distinction is not a good trade.

---

## 8. Exit criteria

| Criterion | Evidence | Status |
|---|---|---|
| Recovery path proven before any change | `run-command` returns `nt authority\system` | Done |
| Link state captured for rollback | `gPLink` saved for both target OUs | Done |
| Phase 7 decryption verified for `sg-it-admins` | `DecryptionStatus: Success` as `cdubois` | Done |
| Phase 7 rotation verified | Password and expiry both moved | Done |
| Tier OU structure created, outside sync scope | Twelve OUs, admin accounts under `NoSync` | Done |
| Per-tier admin accounts created | `t0-admin`, `t1-admin`, `t2-admin` in their groups | Done |
| CS01 relocated to a linkable OU | `CN=CS01,OU=Servers,DC=sindredg,DC=local` | Done |
| Existing deny rights surveyed before authoring | One GPO, two rights, both recorded | Done |
| Local Administrators membership controlled by policy | — | Pending |
| CS01 local administrator under LAPS | — | Pending |
| Deny-logon rights applied by GPO per tier | — | Pending |
| Cross-tier logon attempted and refused | — | Pending |
| Denial captured in the event log | — | Pending |
| `labadmin` retired to break-glass | — | Pending |
| Shared Domain Admin entry in the risk register closed | — | Pending |

---

## 9. Walkthrough status

**Stopped after section 6.** Everything above has been run and its output captured.
Nothing has been denied to anybody yet, and no policy authored in this phase is linked.
The environment is in a safe intermediate state: new objects exist, `labadmin` still
works everywhere, and every previous phase behaves exactly as its own document
describes.

Remaining work, in dependency order:

| # | Step | Why it is next |
|---|---|---|
| 8 | Local Administrators by Group Policy Preferences, on `OU=Servers` and `OU=Workstations` | `t1-admin` and `t2-admin` cannot sign into their own tier until their group is a local administrator |
| 9 | Positive-path verification for all three accounts | A denial only means something once the allowed path is known to work |
| 10 | LAPS permissions on `OU=Servers` | Reuses the Phase 7 pattern against the new OU |
| 11 | `Server-LAPS-AD` GPO, linked to `OU=Servers` | — |
| 12 | Apply and verify CS01's password in AD | Closes the CS01 half of risk 3 |
| 13 | Author the three deny GPOs, unlinked | Must carry the baseline members from section 6 |
| 14 | Group Policy Modeling, then link one tier at a time, Tier 2 first | Lowest blast radius first; Tier 0 last, with the rollback command ready |
| 15 | Test matrix: six accounts against four machines, three logon paths | — |
| 16 | Correlate each denial to its Security event | Event 4625 substatus `0xC000015B`, against 4768 showing a TGT still issued |
| 17 | Retire `labadmin` to break-glass | Only after `t0-admin` is proven |
| 18 | Remove `cdubois` from `sg-it-admins` | Her evidence is banked in section 3 |

**A consequence already accepted for step 14.** Once `Tier1-Logon-Restrictions` is
linked, `t0-admin` cannot sign into CS01 — which is where GPMC lives. DC01 has the
GroupPolicy module but is Server Core, and editing User Rights Assignment is GUI-only.
Group Policy editing therefore becomes a `labadmin` break-glass operation, used
deliberately and logged. The missing piece is a Tier 0 administrative workstation, which
a four-VM lab does not have. That is residual risk, recorded rather than designed
around, and it is the most realistic thing about this phase: tiering creates exactly
this friction, and pretending otherwise would be the dishonest version.
