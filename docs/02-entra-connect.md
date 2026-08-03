# Phase 2. Entra Connect Sync

**Goal:** synchronise the five seeded users from `sindredg.local` into Microsoft
Entra ID, scoped to one OU, so hybrid join in Phase 3 has identities to attach
devices to.

> Installed on CS01. Download from the
> [Microsoft Entra admin center](https://entra.microsoft.com/#view/Microsoft_AAD_Connect_Provisioning/AADConnectMenuBlade/~/GetStarted),
> which is now the only distribution point. See
> [Prerequisites for Microsoft Entra Connect](https://learn.microsoft.com/entra/identity/hybrid/connect/how-to-connect-install-prerequisites).

**Why this matters.** This is the join between the two halves of the lab. Until it
runs, the forest and the tenant are unrelated directories that happen to share a
UPN suffix. Afterwards there is one identity with two representations, which is
what hybrid join in Phase 3 and the Entra-backed LAPS in Phase 6 both build on.

**Status: not yet executed.** The decisions and prerequisites below are settled.
The steps are written from documented behaviour and will be rewritten as a record,
with screenshots, once run.

---

## 1. This phase is free

An earlier version of the plan said Phase 2 was blocked on licensing. That was
wrong, and worth correcting rather than quietly fixing. Microsoft is explicit:

> License requirements for using Microsoft Entra Connect V2: Using this feature is
> free and included in your Azure subscription.

What does need licences is Conditional Access (P1), PIM and access reviews (P2),
and Entra Connect **Health** (P1), which is the monitoring add-on rather than sync
itself. Password writeback and group writeback also need P1 and are not used here.

**There is a version deadline.** Every Connect Sync build below **2.5.79.0 stops
synchronising on 30 September 2026**. Install the current version from the admin
center and enable auto-upgrade.

---

## 2. Connect Sync, not Cloud Sync

Microsoft recommends Cloud Sync for new deployments and calls it the eventual
replacement. We are deliberately not using it.

Cloud Sync does not support device synchronization, and therefore does not support
Microsoft Entra hybrid join. From Microsoft's comparison: *"Connect supports Hybrid
Azure AD Join; not currently supported in Cloud Sync"*. The supported-scenarios
table lists hybrid join against Connect Sync only.

Hybrid join is Phase 3 and the precondition for the Entra-backed LAPS in Phase 6.
Choosing the newer tool would remove the reason this lab exists.

Full comparison in [decisions.md](decisions.md).

---

## 3. Prerequisites on CS01

| Requirement | Why | How to check |
|---|---|---|
| .NET Framework 4.7.2 or later | Hard requirement for 2.5.79.0+ | `(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full').Release` must be 461808 or higher |
| TLS 1.2 enabled | Connect Sync talks to Entra over TLS 1.2 only | Registry under `SCHANNEL\Protocols\TLS 1.2` |
| PowerShell 5.0 or later | Ships with Server 2022 | `$PSVersionTable.PSVersion` |
| Domain-joined | Done in Phase 1 | `Get-ComputerInfo -Property CsDomainRole` reads `MemberServer` |
| Enterprise Admin credentials | For the AD DS connector account | `SINDREDG\labadmin` |
| Hybrid Identity Administrator | For the Entra side of the wizard | The tenant admin account |

**DC01 must be running.** CS01 has no DNS without it, so the wizard cannot resolve
the domain or the tenant.

---

## 4. Installation

Custom settings rather than express, because express syncs the entire directory and
the OU scoping is the point.

| Wizard page | Choice | Reasoning |
|---|---|---|
| Sign-in method | Password Hash Synchronization | Survives an on-premises outage, needs no extra agents. See `decisions.md` |
| Connect to AD DS | `sindredg.local` as `SINDREDG\labadmin` | Enterprise Admin for the connector account |
| Domain and OU filtering | `OU=Sync` only | `OU=NoSync` stays unselected so exclusion is demonstrable |
| Identifying users | Default, `objectGUID` as source anchor | |
| Optional features | None | Password and group writeback both need P1 |

**Include `OU=Workstations` in the scope.** It sits under `OU=Sync` so it is already
covered, but it matters: Phase 3 needs computer objects to sync, and excluding them
breaks hybrid join in a way that is hard to diagnose later.

The UPN suffix work from Phase 1 pays off here. Every seeded user is already on
`@sindredemitriohotmail.onmicrosoft.com`, a verified domain, so the wizard should
not warn about unverified suffixes. If it does, something in `03-prep-sync.ps1` did
not take.

---

## 5. Verification

Force a sync rather than waiting for the 30-minute cycle:

```powershell
Start-ADSyncSyncCycle -PolicyType Delta
```

Then check from the cloud side rather than the server, because the server will
happily report success for objects Entra rejected:

```powershell
Get-MgUser -Filter "onPremisesSyncEnabled eq true" -Property DisplayName,UserPrincipalName |
  Format-Table DisplayName, UserPrincipalName
```

| Check | Expected |
|---|---|
| Synced users | Five: `alindqvist`, `bkarlsson`, `cdubois`, `dvolkov`, `erossi` |
| UPNs | All `@sindredemitriohotmail.onmicrosoft.com` |
| `onPremisesSyncEnabled` | True on all five |
| Service accounts | **Absent.** Anything from `OU=NoSync` appearing means the filter did not apply |
| Sync errors | Zero |

The negative check matters as much as the positive one. Five users appearing proves
sync works; service accounts *not* appearing proves the scoping was real.

---

## 6. Exit criteria

| Criterion | Status |
|---|---|
| Connect Sync installed on CS01, 2.5.79.0 or higher | Pending |
| Password Hash Sync configured | Pending |
| Filtering scoped to `OU=Sync` | Pending |
| Five users in Entra with `onPremisesSyncEnabled` true | Pending |
| Nothing from `OU=NoSync` present in Entra | Pending |
| Zero sync errors | Pending |

---

## Next

Phase 3 enables the two clients, joins them to the domain, and configures hybrid
Entra join through the same Entra Connect wizard. That is the step Cloud Sync could
not have supported, and the precondition for backing a LAPS password up to Entra ID
in Phase 6.

Problems hit during this phase go in [99-troubleshooting.md](99-troubleshooting.md).
