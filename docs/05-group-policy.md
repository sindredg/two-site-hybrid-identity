# Phase 5. Group Policy foundation

> **Status: Pending.** Not yet executed. Written from documented behaviour, to be
> rewritten as a record with screenshots once run.

**Goal:** a Group Policy estate that is designed rather than accumulated, and
version controlled rather than clicked.

> Managed from CS01 using GPMC and RSAT, not from the domain controller.

**Why this matters.** Every later phase is delivered by Group Policy. The security
baselines in Phase 6 arrive as GPOs, the LAPS policy in Phase 7 arrives as a GPO,
and the logon restrictions in Phase 8 are User Rights Assignment inside a GPO. A
badly structured estate makes all three harder to reason about.

---

## 1. The Central Store

ADMX templates live locally on each machine by default, which means the settings
you can see depend on which machine opened GPMC. The Central Store puts one copy in
SYSVOL so every editor sees the same policies.

```powershell
Copy-Item C:\Windows\PolicyDefinitions\* \\sindredg.local\SYSVOL\sindredg.local\Policies\PolicyDefinitions\ -Recurse
```

Windows LAPS templates are **not** installed into the Central Store automatically.
Phase 7 depends on them being there.

---

## 2. Structure

Policy is linked to the OU structure built in Phase 1.

| GPO | Linked to | Type |
|---|---|---|
| `Workstation-Baseline` | `OU=Workstations,OU=Sync` | Computer |
| `User-Standard` | `OU=Users,OU=Sync` | User |
| `LAPS-AD` | `OU=Workstations,OU=Sync`, filtered to CL01 | Computer, Phase 7 |
| `LAPS-EntraID` | `OU=Workstations,OU=Sync`, filtered to CL02 | Computer, Phase 7 |

Two clients in one OU with different LAPS policies is what forces the security
filtering decision recorded in `decisions.md`.

---

## 3. Loopback processing

The setting most often misunderstood. Normally user policy follows the user and
computer policy follows the computer. Loopback makes user policy follow the
*computer* instead, which is how you apply a restricted desktop on a kiosk or a
jump box regardless of who signs in.

Worth demonstrating rather than describing, because the merge versus replace
distinction is where it usually goes wrong.

---

## 4. Verification

Assumption is not verification. Both of these are evidence:

```powershell
gpresult /h C:\gpresult.html
```

```powershell
Get-GPResultantSetOfPolicy -Computer CL01 -ReportType Html -Path C:\rsop.html
```

Group Policy Modeling in GPMC predicts the outcome before a machine is affected,
which is the safer order for anything that could lock an account out.

---

## 5. Getting the estate into the repo

GPOs live in SYSVOL, which is not version control. Back them up to XML and commit:

```powershell
Backup-GPO -All -Path C:\gpo-backup -Domain sindredg.local
```

The output goes to `scripts/gpo/` in the repo. This is what makes the estate
reproducible rather than merely documented, and it is the closest the Group Policy
layer gets to `terraform plan`.

---

## 6. Exit criteria

| Criterion | Status |
|---|---|
| Central Store created and populated | Pending |
| Computer and user GPOs linked to the right OUs | Pending |
| Loopback processing demonstrated and explained | Pending |
| `gpresult` output proving the targeting | Pending |
| `scripts/gpo/` contains restorable backups of every GPO | Pending |

---

## Next

[Phase 6](06-security-baselines.md) imports Microsoft's baselines as GPOs and
measures what they change.
