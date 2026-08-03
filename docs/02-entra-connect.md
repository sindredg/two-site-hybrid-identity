# Phase 2. Entra Connect Sync

**Goal:** synchronise the five seeded users from `sindredg.local` into Microsoft
Entra ID, scoped to one OU, so hybrid join in Phase 4 has identities to attach
devices to.

> Installed on CS01. Downloaded from the
> [Microsoft Entra admin center](https://entra.microsoft.com/#view/Microsoft_AAD_Connect_Provisioning/AADConnectMenuBlade/~/GetStarted),
> which is now the only distribution point. See
> [Prerequisites for Microsoft Entra Connect](https://learn.microsoft.com/entra/identity/hybrid/connect/how-to-connect-install-prerequisites).

**Why this matters.** This is the join between the two halves of the lab. Until it
runs, the forest and the tenant are unrelated directories that happen to share a
UPN suffix. Afterwards there is one identity with two representations, which is
what hybrid join in Phase 4 and the Entra-backed LAPS in Phase 7 both build on.

**Status: complete.** Five users synced with correct UPNs, nothing from the
excluded OU present, zero errors. Problems hit along the way are in
[troubleshooting/02-entra-connect.md](troubleshooting/02-entra-connect.md).

---

## 1. Starting the lab

DC01 starts first, always. CS01 has no DNS without it, and starting the member
server alone gives a machine that cannot resolve anything, including the internet.

```bash
az vm start -g rg-hybridid-swedencentral -n DC01
az vm start -g rg-hybridid-swedencentral -n CS01
```

![Terraform outputs and VM start](images/phase2/vms-started.png)

The outputs also report `bastion_status`, a standing reminder that the Basic SKU
bills hourly whether or not anything is connected to it.

---

## 2. Prerequisites

Checked on CS01 before downloading anything:

```powershell
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full').Release
$PSVersionTable.PSVersion
Get-ComputerInfo -Property CsDomain, CsDomainRole
```

![Prerequisite check on CS01](images/phase2/prerequisites-check.png)

| Requirement | Needed | Found |
|---|---|---|
| .NET Framework | 461808 or higher, meaning 4.7.2 | `528449`, which is 4.8 |
| PowerShell | 5.0 or later | 5.1 |
| Domain-joined | `MemberServer` | `MemberServer` on `sindredg.local` |

TLS 1.2 must be enabled, since Connect Sync talks to Entra over it exclusively.
Read the **values**, not the key names: a key called `SSL 3.0` existing says
nothing about whether the protocol is on.

```powershell
reg query "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols" /s
```

![SCHANNEL protocol keys](images/phase2/tls-protocol-keys.png)

SSL 3.0, TLS 1.0 and TLS 1.1 all `Enabled = 0x0`. TLS 1.2 `Enabled = 0x1`.

---

## 3. Installation

Downloaded from the Entra admin center, which replaced the Download Center as the
only source.

![Download Connect Sync](images/phase2/download-connect-sync.png)

**Custom settings, not express.** Express syncs the entire directory and skips the
OU filtering page, which is the point of this phase.

### Required components

![Install required components](images/phase2/required-components.png)

All five boxes left unticked. Each is a default accepted deliberately:

| Option | What the default gives |
|---|---|
| Custom installation location | `C:\Program Files\Microsoft Azure AD Sync` |
| Use an existing SQL Server | SQL Express LocalDB, capped at 10 GB and roughly 100,000 objects |
| Use an existing service account | A **virtual service account**, with no password to store or rotate |
| Custom sync groups | Four local groups: `ADSyncAdmins`, `ADSyncOperators`, `ADSyncBrowse`, `ADSyncPasswordSet` |
| Import synchronization settings | For migrating config from another Connect server |

The virtual service account matters more than it looks. For a lab whose risk
register already complains about shared credentials, the passwordless default is
the right one to accept.

### Sign-in method

![User sign-in method](images/phase2/user-signin-phs-sso.png)

**Password Hash Synchronization**, because it survives an on-premises outage,
which for a lab whose domain controller is deallocated most of the time is not
hypothetical. It also needs no additional agents. Reasoning in
[decisions.md](decisions.md).

**Seamless SSO enabled.** Strictly redundant here, since hybrid-joined devices get
SSO through the Primary Refresh Token anyway. Enabled because it is free and
because it gives Phase 5 a real Group Policy task: Seamless SSO only works once
`https://autologon.microsoftazuread-sso.com` is in the browser's Intranet zone,
which is a GPO. It also creates a 30-day key rotation obligation, recorded in
[risk-and-limitations.md](risk-and-limitations.md).

### Connecting to the tenant

![Connect to Microsoft Entra ID](images/phase2/connect-to-entra.png)

A dedicated cloud service account rather than a personal admin.

### The AD connector account

![AD forest account, create new](images/phase2/ad-forest-create-new.png)

**Create new AD account**, with Enterprise Admin credentials supplied so the
wizard can mint one. Two different credentials are in play and conflating them is
the mistake to avoid:

| Credential | Used | Stored |
|---|---|---|
| Enterprise Admin | Once, to create the connector account | Never |
| AD DS connector account | Every 30 minutes, forever | **On CS01** |

The wizard creates `MSOL_<hash>` with Replicate Directory Changes and Replicate
Directory Changes All, and nothing else. It lands in the domain's default `Users`
container, outside `OU=Sync`, so it never syncs to the cloud.

Connect Sync will refuse a Domain Admin here, which is correct: if the sync server
is compromised, a stored Domain Admin credential hands over the forest, while a
stored `MSOL_` credential hands over directory read access.

---

## 4. Scoping the sync

The page that justifies the OU structure built in Phase 1:

![OU filtering, Sync only](images/phase2/ou-filtering-sync-only.png)

`Sync` ticked, everything else clear.

| In scope | Contains |
|---|---|
| `OU=Users,OU=Sync` | The five seed users |
| `OU=Groups,OU=Sync` | The four security groups |
| `OU=Workstations,OU=Sync` | Empty now. Phase 4 needs computer objects here for hybrid join |

| Excluded | Why it matters |
|---|---|
| `OU=ServiceAccounts,OU=NoSync` | The point of the exercise. Proves filtering is real |
| `CN=Users` | Holds `labadmin`, `krbtgt`, `Guest` and the `MSOL_` connector account |

**OU filtering is a fixed list, not a rule.** Any OU created later is not synced
automatically. That will matter in Phase 8 when the tier OUs appear.

**Filter users and devices: synchronize all.** The OU filter is already the
boundary. The group-based filter on that page is for pilot rollouts, ignores
nested groups, and layering both makes "why is this not syncing" twice as hard to
answer later.

### Optional features

![Optional features](images/phase2/optional-features.png)

Nothing ticked. Password hash synchronization shows ticked and greyed because it
was chosen as the sign-in method earlier. Password writeback and group writeback
both need P1.

---

## 5. Configuration complete

![Configuration complete](images/phase2/configuration-complete.png)

Four advisories on the final page, three worth acting on:

**AD Recycle Bin is not enabled.** A genuine gap. Without it a deleted user or OU
is recoverable only from a system state backup. One command, irreversible, carried
into Phase 5:

```powershell
Enable-ADOptionalFeature 'Recycle Bin Feature' -Scope ForestOrConfigurationSet -Target sindredg.local
```

**No TPM on the sync server.** Azure Gen2 VMs support vTPM. A Terraform change
rather than a manual fix, noted for later.

**Source anchor is `mS-DS-ConsistencyGuid`**, the modern default. It is written
back into AD, so a user survives being moved between forests or having their
object recreated. `objectGUID` is immutable but tied to one object, so recreating
a user produces a duplicate in the cloud rather than a match.

**Seamless SSO needs Group Policy to finish.** The wizard says so explicitly,
which turns a Phase 5 task from invented to requested.

---

## 6. What this created in the cloud

Connect Sync does not authenticate to Entra with a stored password. It registers
an **application** and authenticates with a certificate.

![App registration roles](images/phase2/app-registration-roles.png)

`ConnectSyncProvisioning_CS01_3ac06f5648e4`. The name encodes the server it runs
on and an installation hash, which is how you tell one sync server's identity from
another in a tenant that has several. That hash also appears in the `MSOL_`
connector account name on-premises, tying the two halves of the identity together.

![App registration API permissions](images/phase2/app-registration-permissions.png)

All permissions are **Application** type, admin-consented at install:

| Permission | Grants |
|---|---|
| `ADSynchronization.ReadWrite.All` | Read, write and manage identity synchronization |
| `PasswordWriteback` (three scopes) | Self-service password reset writeback |

**The password writeback permissions are consented but unused.** The feature was
left off because it needs P1, yet the app registration still holds the rights.
Consented permission and enabled functionality are different things, and the gap
between them is exactly what to look for when auditing a tenant: this app *could*
write passwords back, it simply is not configured to.

**This replaced the old sync service account.** Older versions created a cloud
account named `Sync_<server>_<hash>@tenant.onmicrosoft.com` with a stored
password. Application plus certificate is better on every axis: nothing to leak or
rotate, permissions auditable in one place, and revocation means deleting an app
registration rather than hunting for an account.

---

## 7. Verification

```powershell
Start-ADSyncSyncCycle -PolicyType Initial
```

![Connect Sync status](images/phase2/sync-status.png)

![User sign-in configuration](images/phase2/user-signin-status.png)

Sync enabled, last sync under an hour ago, Password Hash Sync enabled, Seamless
SSO enabled on one domain. Federation and pass-through authentication both
disabled, which is what choosing PHS means in practice.

![Synced users in Entra](images/phase2/synced-users.png)

| Check | Expected | Result |
|---|---|---|
| Synced users | Five: `alindqvist`, `bkarlsson`, `cdubois`, `dvolkov`, `erossi` | All five present |
| UPN suffix | `@<tenant>.onmicrosoft.com` | Correct |
| On-premises sync enabled | True on all five | Yes on all five |
| Service accounts from `OU=NoSync` | Absent | Absent |
| `MSOL_` connector account | Absent from the cloud | Absent |
| Sync errors | Zero | Zero |

**The negative checks carry as much weight as the positive ones.** The one row
reading `On-premises sync enabled: No` is `Service Account`, the cloud-only
identity used to run the wizard. It is in the tenant but was never in the forest,
so it correctly reports as not synced. Nothing from `OU=NoSync` appears at all,
which is what proves the OU filtering did real work rather than being decorative.

---

## 8. Exit criteria

| Criterion | Status |
|---|---|
| Connect Sync installed on CS01, 2.5.79.0 or higher | Done, 2.6.84.0 |
| Password Hash Sync configured | Done |
| Filtering scoped to `OU=Sync` | Done |
| Five users in Entra with sync enabled | Done |
| Nothing from `OU=NoSync` present in Entra | Done |
| Zero sync errors | Done |

---

## 9. Carried forward

| Item | Where |
|---|---|
| Re-enable IE ESC on CS01 | Set `IsInstalled` back to `1`. Disabled for the installer, not permanently |
| Enable AD Recycle Bin | Phase 5 |
| Roll the Seamless SSO Kerberos key every 30 days | Ongoing. See `risk-and-limitations.md` |
| Consider vTPM on CS01 | Optional Terraform change |

---

## Next

[Phase 3](03-branch-network.md) enables CL01 and CL02, joins them to the domain, and
configures hybrid Entra join through this same wizard. That is the step Cloud Sync
could not have supported, and the precondition for backing a LAPS password up to
Entra ID in Phase 7.


---

## Note: This phase was free

Connect Sync needs no licence. Microsoft is explicit: *"License requirements for
using Microsoft Entra Connect V2: Using this feature is free and included in your
Azure subscription."*

What does need licences is Conditional Access (P1), PIM and access reviews (P2),
and Entra Connect **Health** (P1), which is the monitoring add-on rather than sync
itself. Password writeback and group writeback also need P1 and are not used here.

**There is a version deadline.** Every build below **2.5.79.0 stops synchronising
on 30 September 2026**. This lab installed 2.6.84.0.

**Connect Sync, not Cloud Sync.** Cloud Sync cannot do device synchronization, and
therefore cannot do hybrid Entra join, which is Phase 4 and the precondition for
Phase 7. Full comparison in [decisions.md](decisions.md).

