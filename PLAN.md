# Roadmap

Phases ordered by dependency, not preference. Each is blocked by the one above it,
and each states what "done" means so progress is checkable rather than asserted.

Status legend: Completed, In progress, Ready to start, Pending, Not implemented.

The lab has two halves that meet at the end. Phases 2 to 4 connect the forest to
Microsoft Entra ID. Phases 5 to 8 manage and harden the endpoints inside it. Phase
7 is where they join: Group Policy delivering a LAPS policy whose secret lands in
the cloud.

Phase 3 is a networking layer that was not in the original plan. The endpoints live
in a second region, peered back to the domain controller, because that was the only
way to fit them inside a free trial's quota. It earned its place: Phase 4 has real
AD Sites and Services work because of it.

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
OU, so hybrid join in Phase 4 has identities to attach devices to.

Walkthrough: [docs/02-entra-connect.md](docs/02-entra-connect.md).

Connect Sync 2.6.84.0 on CS01, Password Hash Synchronization with Seamless SSO,
filtering scoped to `OU=Sync`. Authentication to the tenant is by app registration
and certificate rather than a stored password.

**Connect Sync, not Cloud Sync.** Cloud Sync cannot do device synchronization,
which means it cannot do hybrid join. Reasoning in `docs/decisions.md`.

**Exit criteria met.** Five users in Entra with on-premises sync enabled, correct
UPN suffix on all of them, nothing from `OU=NoSync` present, zero sync errors.

**Carried forward.** Re-enable IE ESC on CS01, enable the AD Recycle Bin in Phase
5, and roll the Seamless SSO Kerberos key every 30 days.

---

## Phase 3. Branch office network: Completed

**Goal.** A second site in a second region, peered back to the domain controller.

Walkthrough: [docs/03-branch-network.md](docs/03-branch-network.md).

**Forced, then kept.** The clients would not fit inside the Sweden Central vCPU
quota, which a free trial cannot raise. Rather than shrink the lab, they moved to
their own region, resource group and Terraform state. That turned a dead end into
cross-region peering and a genuine reason for AD Sites and Services in Phase 4.

Delivered:

| Item | Detail |
|---|---|
| Second region | Denmark East, chosen because it had both spare quota and the same VM size as HQ |
| Second state | `terraform/azure-denmarkeast/branch/`, own resource group `rg-branch-office` |
| Global VNet peering | Both directions, owned by the branch root |
| Shared module | `terraform/modules/windows-vm/`, encoding earlier failures as plan-time validations |
| One Bastion for both sites | Basic SKU reaches peered networks, so no second host |

**Cost note.** Denmark East does not publish `Microsoft.DevTestLab`, so the branch
clients have no auto-shutdown schedule and must be deallocated by hand.

**Exit criteria met.** Peering `Connected` both ways, clients on their intended
addresses, and DC01 answering from the branch at roughly 16 ms.

---

## Phase 4. Sites, domain join and hybrid Entra join: Completed

**Goal.** Make the directory aware it spans two sites, join both clients, and
register them with Entra ID. The precondition for the cloud half of Phase 7.

Walkthrough: [docs/04-hybrid-join.md](docs/04-hybrid-join.md).

Delivered:

| Item | Detail |
|---|---|
| AD Sites and Services | `HQ-SwedenCentral` and `Branch-DenmarkEast`, each with its subnet |
| Domain join | Both clients, straight into `OU=Workstations,OU=Sync` via `-OUPath` |
| Service connection point | Written to the forest by the Entra Connect wizard |
| Hybrid join | Both clients `AzureAdJoined: YES` and `DomainJoined: YES` |

**Site awareness is the part worth showing.** `nltest` from a branch client reports
`Our Site Name: Branch-DenmarkEast` against `Dc Site Name: HQ-SwedenCentral`. Two
different values in one output is what a multi-site directory looks like, and it
only exists because Phase 3 split the lab.

**No licence required.** Hybrid join is free. Only the Conditional Access that
would normally sit on top of it needs P1.

**Exit criteria met.** Both devices listed as Microsoft Entra hybrid joined in the
portal, both subnets bound to named sites, and `dsregcmd /status` confirming both
joins on both clients.

---

## Phase 5. Group Policy foundation: Completed

**Goal.** A GPO estate that is designed rather than accumulated, and version
controlled rather than clicked.

Walkthrough: [docs/05-group-policy.md](docs/05-group-policy.md).

Delivered so far:

| Item | Detail |
|---|---|
| Central Store | 214 templates and 215 language files in SYSVOL, pairing verified, GPMC confirming it reads from the store. `LAPS.admx` present for Phase 7 |
| Three GPOs | `Workstation-Baseline` and `Loopback-Demo` on `OU=Workstations`, `User-Standard` on `OU=Users` |
| ICMP by policy | Inbound echo scoped to the two AD Sites subnets, closing an observation open since Phase 3 |
| Seamless SSO | The intranet zone assignment the feature has needed since Phase 2 |
| Security filtering | `Loopback-Demo` reduced to CL02 alone, rehearsing what Phase 7 needs |
| Measured, not asserted | Ping across the peering failing before the refresh and answering at 16 ms after |
| Carried-forward items | AD Recycle Bin enabled, IE ESC restored on CS01 |

**The firewall result is the one worth reading.** After `gpupdate` on CL01, CS01
reaches it at 16 ms and CL01 still cannot reach CS01, because CS01 sits in
`CN=Computers` and receives no policy. A network change would have fixed both
directions at once, so the asymmetry is what proves Group Policy did it.

**One gap, named rather than hidden.** `Loopback-Demo` is built and filtered to CL02
but carries no loopback setting. CL02 is the untouched control Phase 6 measures
against, and putting user configuration on it would weaken that comparison, so the
GPO was unlinked and CL02 enters Phase 6 clean. The security filtering it was built
to rehearse is complete and evidenced.

**Carried into Phase 6.** Restoring IE ESC means the Security Compliance Toolkit must
be fetched with `Invoke-WebRequest` rather than through a browser. Exporting the GPO
estate into the repository is deferred, since Bastion Basic has no file transfer and
a half-built export is worse than none.

**Exit criteria met.** Policies apply to the right targets, and `gpresult`, the
client firewall store, the operational event log and `Get-GPResultantSetOfPolicy` all
confirm it independently of each other.

---

## Phase 6. Security baselines: Completed

**Goal.** Apply Microsoft's own hardening guidance and measure the difference rather
than trusting it.

Walkthrough: [docs/06-security-baselines.md](docs/06-security-baselines.md).

Delivered:

| Item | Detail |
|---|---|
| Version-matched baseline | Server 2022 Member Server GPO, one of the eight in the pack, against Server 2022 clients |
| Scoped to one endpoint | Security filtering to `CL01$`, link order 1 so the baseline wins on conflict |
| Predicted before applied | Modeling showed CL01 applied and CL02 denied, before either machine refreshed |
| Measured, not asserted | User Rights Assignment and Advanced Audit Configuration exist on CL01 and are absent on CL02 |

**The interesting part was what broke.** CL01 no longer accepts the local `labadmin`
account over Bastion, because the baseline sets `Deny log on through Terminal
Services` to `Local account` and `Deny access to this computer from the network` to
`Local account and member of Administrators group`. That is the flat shared credential
in `risk-and-limitations.md` entry 3 being refused by policy, which is the behaviour
the baseline is for.

**Firewall profile and firewall rules are separate policy areas.** The baseline owns
the profile on CL01 while the Phase 5 ICMP and WMI rules stay owned by
`Workstation-Baseline`. They merge rather than compete, so a baseline can harden the
profile without touching a single rule.

**Policy Analyzer was dropped.** It runs on the endpoint rather than centrally, its
comparison step is GUI-only, and on the hardened client the baseline blocked it from
starting. Modeling answered the same question with less friction. Reasoning in
`decisions.md` entry 16.

**Exit criteria met.** Baseline applied to CL01 and denied on CL02, the difference
shown in reports that name the winning GPO for every setting, and every deviation
recorded in `decisions.md`.

---

## Phase 7. Windows LAPS, both backends: Completed

**Goal.** Remove the shared local administrator password, and demonstrate the two
LAPS storage modes side by side. This is where the two halves of the lab meet.

Walkthrough: [docs/07-windows-laps.md](docs/07-windows-laps.md).

A hybrid-joined device backs its password up to **either** Active Directory **or**
Entra ID, never both. With two clients, one of each:

| Client | Backup directory | Retrieved with |
|---|---|---|
| CL01 | Active Directory, encrypted to `sg-it-admins` | `Get-LapsADPassword` |
| CL02 | Microsoft Entra ID | Local administrator password recovery |

Both policies delivered by **Group Policy**, built in Phase 5. Intune not required
and not used.

Delivered:

| Item | Detail |
|---|---|
| Schema extended | Six `msLAPS-*` attributes plus the `ms-LAPS-Encrypted-Password-Attributes` extended right. Irreversible |
| Three separate rights | Machines write their own password, `sg-it-admins` reads, `sg-it-admins` resets |
| Two filtered GPOs | Identical except for the backend, one per client |
| Encryption at rest | AD side encrypted to a Tier 1 group rather than the Domain Admins default |

**The result worth showing is a refusal.** Reading CL01's password as `labadmin`,
sole member of Domain Admins, returns the object with
`DecryptionStatus: Unauthorized`. A directory ACL and an encryption principal are
independent gates, and forest administration passes only the first.

**LAPS manages the account that mattered.** `labadmin` turned out to be RID 500,
because Azure renames the built-in Administrator rather than creating a second
account, and LAPS targets that account by RID rather than by name.

The forest is at Windows2016 functional level with a Server 2022 domain controller,
which is the configuration where AD-side password **encryption** and **DSRM account
management** both work. On an older domain neither is available.

**Licensing.** The LAPS feature is free. AD backup needs nothing. Entra ID backup
needs Entra ID Free, which every tenant has.

**Exit criteria met, with two verifications outstanding.** Both clients hold
machine-specific rotating passwords in different directories. Not captured: a
successful decryption as `sg-it-admins`, and a rotation. Both are recorded in the
phase document rather than assumed.

**Carried forward.** The shared-credential entry in `risk-and-limitations.md`
**partially** closes. CL01 and CL02 are covered; CS01 still holds the shared
Terraform password because it sits in `CN=Computers` where no GPO can reach it, and
the domain `labadmin` is untouched. Both are Phase 8.

**Not done.** DSRM password management on DC01, which the schema extension prepared
for. Optional, and skipped to close the phase.

---

## Phase 8. Tiered administration: Planned, not implemented

**Current position.** This optional hardening phase has not been executed or
validated. The current milestone ends after Phase 7, which already demonstrates the
two-site infrastructure, hybrid identity, Group Policy, security-baseline and
Windows LAPS outcomes. The design below remains available for a later continuation
and must not be read as deployed.

**Goal.** Stop using one Domain Admin account for everything, which is the other
weakness the risk register names.

1. Tier 0 / Tier 1 / Tier 2 OU structure with separate admin accounts
2. Deny logon rights across tiers via User Rights Assignment in GPO
3. Restricted Groups to control local administrator membership on the clients
4. Prove the boundary by attempting a cross-tier logon and having it refused

**Exit criteria.** A documented, tested failure: a lower-tier account denied access
to a higher-tier machine, with the event log entry to show it.

Deferred because Phases 0 to 7 already tell a complete portfolio story for the
current milestone. A later continuation can revisit the tier model together with
privileged workstations, stronger identity licensing and operational recovery.

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
