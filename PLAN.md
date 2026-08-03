# Roadmap

Phases ordered by dependency, not preference. Each is blocked by the one above it,
and each states what "done" means so progress is checkable rather than asserted.

Status legend: Completed, In progress, Ready to start, Pending, Stretch.

The lab has two halves that meet at the end. Phases 2 and 3 connect the forest to
Microsoft Entra ID. Phases 4 to 7 manage and harden the endpoints inside it. Phase
6 is where they join: Group Policy delivering a LAPS policy whose secret lands in
the cloud.

Phase 3 also carries a networking layer that was not in the original plan. The
endpoints live in a second region, peered back to the domain controller, because
that was the only way to fit them inside a free trial's quota.

> **Everything here is free.** Entra Connect Sync, hybrid Entra join and Windows
> LAPS all work on Entra ID Free. The lab stops deliberately before Conditional
> Access (P1) and PIM (P2), which are unobtainable for this tenant. That boundary
> is documented rather than worked around; see [docs/decisions.md](docs/decisions.md).

---

## Phase 0. Azure infrastructure: Completed

Resource group `rg-hybridid-swedencentral`. VNet, subnet, NSG, Bastion, and the
VMs with their NICs, disks and auto-shutdown schedules. All Terraform, in
`terraform/azure/`. Walkthrough in `docs/00-infrastructure.md`.

| Delivered | Detail |
|---|---|
| No internet-facing surface | Public IPs removed, single inbound NSG rule scoped to `VirtualNetwork` |
| Bastion access | Basic SKU, gated behind `enable_bastion` |
| Static private IPs | DC01 `10.10.1.4`, CS01 `10.10.1.5` |
| Cost control | Daily auto-shutdown, Bastion gated behind `enable_bastion` |

The clients were originally planned for this subnet on `.6` and `.7`. They did not
fit the region's vCPU quota and now live in a peered branch office; see Phase 3.

**Exit criteria met.** `terraform plan -detailed-exitcode` returns 0.

---

## Phase 1. AD environment: Completed

Forest `sindredg.local`, NetBIOS `SINDREDG`, domain and forest functional level
Windows2016. Walkthrough in `docs/01-ad-environment.md`.

Six OUs split into `OU=Sync` and `OU=NoSync`, four security groups, five seed
users enabled with UPNs on the tenant's verified domain.

**Exit criteria met.** Member server domain-joined, five users enabled, `dcdiag`
clean, `03-prep-sync.ps1` reporting no blockers.

---

## Phase 2. Entra Connect Sync: Completed

**Goal.** Synchronise the five seeded users into Microsoft Entra ID, scoped to one
OU, so hybrid join in Phase 3 has identities to attach devices to.

Walkthrough: [docs/02-entra-connect.md](docs/02-entra-connect.md).

Connect Sync 2.6.84.0 on CS01, Password Hash Synchronization with Seamless SSO,
filtering scoped to `OU=Sync`. Authentication to the tenant is by app registration
and certificate rather than a stored password.

**Connect Sync, not Cloud Sync.** Cloud Sync cannot do device synchronization,
which means it cannot do hybrid join. Reasoning in `docs/decisions.md`.

**Exit criteria met.** Five users in Entra with on-premises sync enabled, correct
UPN suffix on all of them, nothing from `OU=NoSync` present, zero sync errors.

**Carried forward.** Re-enable IE ESC on CS01, enable the AD Recycle Bin in Phase
4, and roll the Seamless SSO Kerberos key every 30 days.

---

## Phase 3. Branch office and hybrid Entra join: In progress

**Goal.** A second site in a second region, peered back to the domain controller,
with clients joined to both directories. The second half is the precondition for the
cloud half of Phase 6.

Walkthrough: [docs/03-hybrid-join.md](docs/03-hybrid-join.md).

**The branch office was forced, then kept.** The clients would not fit inside the
Sweden Central vCPU quota, which a free trial cannot raise. Rather than shrink the
lab, they moved to their own region, resource group and Terraform state. That turned
a dead end into cross-region peering, DNS and Kerberos over that peering, and a
genuine reason for AD Sites and Services.

Done:

1. Clients removed from the HQ root, orphaned NICs cleaned up
2. `terraform/branch/` built: own resource group, VNet `10.20.0.0/16`, NSG, both
   peering objects, clients on `10.20.1.4` and `10.20.1.5`
3. `terraform/modules/windows-vm/` extracted, encoding the lab's earlier failures as
   plan-time validations
4. Peering verified: DC01 answers from the branch at roughly 16 ms

Remaining:

5. Domain join CL01 and CL02, move their computer objects into `OU=Workstations`
6. Confirm computer objects reach Entra, since hybrid join depends on it
7. Run the hybrid join configuration wizard in Entra Connect
8. Verify with `dsregcmd /status`
9. Define both sites and subnets in AD Sites and Services

**No licence required.** Hybrid join is free. Only the Conditional Access that
would normally sit on top of it needs P1.

**Cost note.** The branch region does not publish `Microsoft.DevTestLab`, so those
two clients have no auto-shutdown schedule and must be deallocated by hand.

**Exit criteria.** `AzureAdJoined: YES` and `DomainJoined: YES` on both clients,
both listed as Microsoft Entra hybrid joined in the portal, and both subnets bound
to named sites.

---

## Phase 4. Group Policy foundation: Pending

**Goal.** A GPO estate that is designed rather than accumulated, and version
controlled rather than clicked.

1. Create the Group Policy Central Store on DC01 so ADMX templates are consistent
2. Build linked GPOs against the OU structure: user policy on `OU=Users`, computer
   policy on `OU=Workstations`
3. Demonstrate loopback processing, the setting most often misunderstood
4. Verify with `gpresult /h` and Group Policy Modeling, not by assuming
5. Back every GPO up to XML with `Backup-GPO` and commit it, so the estate lives in
   the repo rather than only in SYSVOL

**Exit criteria.** Policies apply to the right targets, `gpresult` proves it, and
`scripts/gpo/` contains restorable backups.

---

## Phase 5. Security baselines: Pending

**Goal.** Apply Microsoft's own hardening guidance and measure the difference
rather than trusting it.

1. Download the Microsoft Security Compliance Toolkit onto CS01
2. Import the Windows Server 2022 member server baseline as GPOs
3. Apply it to CL01 and leave CL02 as an untouched control
4. Use Policy Analyzer to compare hardened against control, and commit the output

**Two clients exist for this.** A single machine only lets you assert that a
baseline was applied. A hardened machine beside an untouched one makes the
comparison evidence.

**The interesting part is what breaks.** A baseline applied wholesale to a lab will
disable something needed. Which setting broke what, and the reasoning for each
exception, is the actual content of this phase.

**Exit criteria.** Baseline applied to CL01, Policy Analyzer output committed, and
every deviation recorded in `decisions.md` with a reason.

---

## Phase 6. Windows LAPS, both backends: Pending

**Goal.** Remove the shared local administrator password, and demonstrate the two
LAPS storage modes side by side. This is where the two halves of the lab meet.

A hybrid-joined device can back its password up to **either** Active Directory
**or** Entra ID, not both. With two clients we do one of each:

| Client | Backup directory | Retrieved with |
|---|---|---|
| CL01 | Active Directory | `Get-LapsADPassword` |
| CL02 | Microsoft Entra ID | Entra admin center or Graph |

Both policies are delivered by **Group Policy**, built in Phase 4. Intune is not
required and is not used.

1. Extend the schema: `Update-LapsADSchema`, a one-time forest operation
2. Grant devices permission to write their own password:
   `Set-LapsADComputerSelfPermission -Identity "OU=Workstations,OU=Sync,DC=sindredg,DC=local"`
3. Enable LAPS in the tenant: Entra admin center, Devices, Device settings
4. Configure two LAPS GPOs differing only in `BackupDirectory`
5. Retrieve a password from each backend and confirm rotation
6. Enable DSRM password management on DC01

The forest is at Windows2016 functional level with a Server 2022 domain
controller, which is the configuration where AD-side password **encryption** and
**DSRM account management** both work. On an older domain neither is available.

**Licensing.** The LAPS feature is free. AD backup needs nothing. Entra ID backup
needs Entra ID Free, which every tenant has.

**Exit criteria.** Both clients have machine-specific rotating passwords, one
stored encrypted in AD and one in Entra ID, each retrievable only by an authorised
principal. The shared-credential entry in `risk-and-limitations.md` closes.

---

## Phase 7. Tiered administration: Stretch

**Goal.** Stop using one Domain Admin account for everything, which is the other
weakness the risk register names.

1. Tier 0 / Tier 1 / Tier 2 OU structure with separate admin accounts
2. Deny logon rights across tiers via User Rights Assignment in GPO
3. Restricted Groups to control local administrator membership on the clients
4. Prove the boundary by attempting a cross-tier logon and having it refused

**Exit criteria.** A documented, tested failure: a lower-tier account denied access
to a higher-tier machine, with the event log entry to show it.

Marked stretch because Phases 2 to 6 already tell a complete story. This is the
phase to drop if the lab has gone on long enough.

---

## Where the lab stops

Conditional Access is the natural next step after hybrid join: require a
hybrid-joined device for admin access, and the two halves of this lab become one
control. It needs Entra ID P1, which is unobtainable here, so the lab stops at the
capability boundary rather than pretending past it.

That boundary is worth stating plainly in a portfolio. Knowing exactly which
feature needs which licence, and designing to what you actually have, is a more
useful signal than a lab that quietly assumes an E5 tenant.

---

## Notes

**Cost control.** Auto-shutdown stops the HQ VMs daily and does not restart them.
The branch clients have no schedule, because that region does not publish the
resource type, so they need `az vm deallocate` by hand. Bastion is gated behind
`enable_bastion` and bills hourly while it exists. `terraform destroy` removes
everything, branch root first.

**Evidence.** Each phase should leave something a reader can check: a synced user
in Entra, `dsregcmd /status`, `gpresult` output, a Policy Analyzer comparison, a
retrieved LAPS password from each backend. The lab is not the deliverable, the
evidence that it works is.

**Known gaps.** State is local, unlocked and unversioned, and holds the admin
password in plaintext. Recorded in `docs/risk-and-limitations.md` rather than
pretended away.
