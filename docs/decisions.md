# Decisions

Choices made during the build, with the reasoning and what was given up. Recorded
so the alternatives are visible rather than implied.

---

## 1. Tooling is split by layer, not unified

No single tool covers all three layers well.

| Layer | Tool | Reasoning |
|---|---|---|
| Azure infrastructure | Terraform `azurerm` | Declarative, diffable, destroys cleanly |
| Forest, OUs, users, groups | PowerShell | Terraform cannot promote a forest at all |
| Endpoint configuration | Group Policy | The native mechanism, and the only one available without Intune |
| Security baselines | Microsoft Security Compliance Toolkit | Microsoft ships these as GPO backups, not as code. Imported, then measured with Policy Analyzer |

**Rejected: `hashicorp/ad` for the directory layer.** Version 0.5.0, last
published March 2024, effectively dormant. It also needs WinRM reachability to
the domain controller, which the Bastion-only network design deliberately
removes. Choosing it purely to claim "all IaC" would mean fighting a stale
provider to do something it was never designed for.

**Given up.** The directory layer has no plan and no drift detection. Mitigated by
making the scripts idempotent, so re-running is the drift check.

---

## 2. One Terraform root, under `terraform/azure/`

> **Superseded by entry 13.** There are two roots now. The reasoning below is why
> there was briefly only one, and the principle in its closing line is what entry 13
> then applied. Kept rather than deleted, because the reversal is the interesting
> part.

The layout originally had two roots, `terraform/azure/` and `terraform/entra/`,
kept separate on blast-radius grounds: a bad Conditional Access apply can lock
every administrator out of a tenant, and that plan should never be able to rebuild
a domain controller as well.

That reasoning was sound but the root was empty. The Entra layer here is Connect
Sync and hybrid join, both configured by a wizard on a member server rather than by
Terraform, and the Conditional Access that would have justified a separate state
file is out of scope on licensing grounds. A root holding nothing is worse than no
root, so it was removed.

The nesting under `terraform/azure/` stays, because a second root remains plausible
later and moving a Terraform root once state exists is more disruptive than leaving
a directory in place.

**Given up.** Nothing currently. The principle is worth retaining: separate state
for anything whose worst-case failure differs from the rest of the stack.

---

## 3. Azure Bastion instead of public IPs

Originally each VM had a Standard static public IP with an NSG rule allowing RDP
from a single home address.

**Changed because** the home IP rotates, which silently breaks access, and more
importantly a domain controller with an internet-facing RDP port is the wrong
thing to publish in a portfolio. The immediate trigger was that `mstsc.exe` does
not exist on recent Windows 11 Home ARM64 builds, so RDP was not usable anyway.

**Developer SKU over Basic, then reversed.** Developer is free, so it went in
first. It proved too unreliable to work against: mostly failing to connect, and
black-screening then dropping when it did. Everything on our side was healthy, and
the intermittency was the tell, since a config or firewall block fails identically
every time. The shared pool was the only remaining explanation.

We moved to **Basic**, which is dedicated and needs an `AzureBastionSubnet` at
`10.10.2.0/26` plus a Standard static public IP.

**The cost reasoning that chose Developer was wrong.** It anchored on $139/month,
which is the 24/7 figure. Bastion bills hourly at $0.19, and Terraform can create
and destroy it on demand, so a working session costs pennies. The host is gated
behind `enable_bastion`; setting it false and applying stops the meter while the
subnet, which is free, stays put.

**Given up.** A few dollars a month against a free tier that did not work. The
`AzureBastionSubnet` must never carry the lab NSG, because Bastion needs its own
rule set and a partial one breaks the service in ways that look like a VM fault.

---

## 4. Every private IP is static

DC01 is pinned to `10.10.1.4` because the VNet DNS setting must point at a fixed
address. CS01 and CL01 were originally dynamic.

**Changed because** Azure allocates dynamic addresses from the lowest free one,
which is `10.10.1.4`, and Terraform creates NICs in parallel. A dynamic NIC won
the race and took the DC's address. See `troubleshooting/00-infrastructure.md`.

**Given up.** Nothing meaningful. Predictable addressing is a feature in a lab
this size.

---

## 5. Provider pinned to azurerm `~> 4.2`, not 5.x

azurerm 5.0 changed the default `resource_provider_registration` from `legacy` to
`none`. On a subscription where `Microsoft.DevTestLab` was never registered, that
breaks the auto-shutdown schedules with an error that does not obviously point at
provider registration.

**Given up.** Newer resources and fixes in 5.x. Revisit by setting
`resource_providers_to_register` explicitly.

---

## 6. Server Core on DC01

Desktop Experience would run on 4 GB, but Core is the correct habit for a domain
controller: smaller attack surface, fewer patches, less RAM spent on a GUI that
gets used for ten minutes.

**Given up.** No local GUI tooling. Administration is PowerShell, or RSAT from
CS01 once it is joined. This is the intended lesson, not a limitation.

---

## 7. Forest is `sindredg.local`, UPN suffix is the tenant's onmicrosoft domain

The forest is `sindredg.local`, NetBIOS `SINDREDG`. The tenant's only verified
domain is `<tenant>.onmicrosoft.com`, so the on-prem domain and the
UPN suffix are deliberately different.

**Rejected: a single-label domain.** A bare `sindredg` with no suffix is
unsupported by Microsoft and breaks Entra Connect.

**Rejected: a routable domain such as `sindredg.com`.** It would let the on-prem
suffix match a verified Entra domain, removing the retargeting step entirely.
Not available, because no such domain is owned and a DNS TXT record cannot be
added to prove it.

**Given up.** `.local` cannot be verified in Entra, so users created with a
`@sindredg.local` UPN would sync as `@<tenant>.onmicrosoft.com`
regardless. `03-prep-sync.ps1` adds the onmicrosoft domain as an alternative UPN
suffix in the forest and retargets the seed users onto it before sync.

That split is precisely the state a real `.local`-era environment is in before its
first sync, so the lab demonstrates the same remediation a migration would need.

---

## 8. The lab stops at the licence wall, not before it

Entra ID P1 and P2 are unobtainable for this tenant. The instinct was to drop
Microsoft Entra ID from the project entirely. Checking what actually needs a
licence showed that was wider than necessary:

| Capability | Licence | Available here |
|---|---|---|
| Entra Connect Sync, PHS, OU filtering | None | Yes |
| Hybrid Entra join | None | Yes |
| Seamless SSO | None | Yes |
| Windows LAPS, backup to Active Directory | None | Yes |
| Windows LAPS, backup to Entra ID | Entra ID Free | Yes |
| Conditional Access | P1 | No |
| PIM, access reviews, Identity Protection | P2 | No |
| Password writeback, group writeback, Connect Health | P1 | No |

So the wall sits between hybrid join and Conditional Access, not before
synchronisation. The lab runs right up to it and stops.

**Rejected: dropping Entra entirely.** Considered, and briefly implemented. It
would have discarded the two phases that make this project different from a
generic Windows Server lab, for no licensing reason.

**Rejected: buying a single P1 licence.** At roughly $6 per user per month this was
affordable and Conditional Access would have survived. Not pursued because no paid
licences were available for this tenant at all.

**Rejected: writing Conditional Access policies without applying them.** Terraform
that is never planned or applied is unverifiable. The whole argument for
policy-as-code is that it is testable.

**Given up.** The device-based Conditional Access that would have tied hybrid join
to an access decision. That is the natural next step and it is named in `PLAN.md`
as where the lab stops, rather than omitted.

Stating exactly which feature needs which licence, and designing to what is
actually available, is a more useful signal than a lab that quietly assumes an E5
tenant.

---

## 9. Entra Connect Sync, not Cloud Sync

Microsoft recommends Cloud Sync for new deployments and describes it as the
eventual replacement for Connect Sync. We are using Connect Sync anyway.

**Reason: Cloud Sync cannot do hybrid Entra join.** From Microsoft's comparison,
Device Synchronization is supported in Connect Sync and not in Cloud Sync, with the
note "Connect supports Hybrid Azure AD Join; not currently supported in Cloud Sync".

| Capability | Connect Sync | Cloud Sync |
|---|---|---|
| Users, groups, contacts | Yes | Yes |
| Password hash sync | Yes | Yes |
| OU-based filtering | Yes | Yes |
| **Device synchronization** | **Yes** | **No** |
| **Hybrid Entra join** | **Yes** | **No** |
| Disconnected forests | No | Yes |
| Cloud-managed config | No | Yes |

**Given up.** An on-premises server that is a single point of failure, config that
lives on that server rather than in the cloud, and a product line Microsoft is
steering away from. All acceptable: the lab has one forest, one sync server, and a
hard requirement Cloud Sync cannot meet.

---

## 10. Password Hash Sync, not Pass-through Authentication

**Reason.** PHS keeps authentication working if the on-premises environment is
unavailable, which for a lab whose domain controller is deallocated most of the
time is not hypothetical. It needs no additional agents.

**Given up.** Password hashes leave the on-premises boundary, as a hash of a hash
rather than the password or the original hash. For an organisation whose policy
forbids that, PTA or federation is the answer, and the trade-off should be stated
rather than assumed.

---

## 11. Four machines, and CS01 keeps its name

**Two clients, not one.** Phase 6 applies a security baseline to CL01 and leaves
CL02 untouched as a control, so Policy Analyzer has something to compare against.
Phase 7 then points each at a different LAPS backend, one to Active Directory and
one to Entra ID, demonstrating both storage modes in one environment. A second
client is the cheapest way to turn an assertion into a comparison.

**Rejected: renaming CS01 to MGMT01.** Proposed and briefly implemented while
Microsoft Entra ID was out of scope, when the machine's only remaining job was
management tooling and "Connect Server" described nothing.

Reverted once sync came back into scope, for three reasons. The name is accurate
again: CS01 runs Entra Connect Sync, and running the management tooling alongside
it is what a real Connect server usually does. The map key is the VM name, so a
rename replaces the VM, its NIC, its disk and its shutdown schedule, and orphans
the computer object in Active Directory. And every Phase 1 screenshot shows CS01,
so a rename would put the evidence permanently out of step with the environment.

The general point is worth keeping: rename while a machine is empty or not at all,
and weigh a better name against the cost of invalidating your own evidence.

**Managing from CS01, not the DC.** Logging into a domain controller to run tooling
is the habit that makes a tiered administration model meaningless before it starts.

**Given up.** A fourth VM's standing disk cost, and a fifth that would have been a
dedicated privileged-access workstation for Phase 8. CS01 plays the Tier 1 box
instead.

---

## 12. Splitting the lab across two regions

**Decision.** Move CL01 and CL02 out of Sweden Central into a second region, a
second resource group, and a second Terraform state, joined by global virtual
network peering.

**Forced, then kept.** Sweden Central is capped at 4 vCPU on a free trial, on two
separate counters, and DC01 and CS01 consume all of it. A support request is the
normal answer and is not available on a free trial. The immediate options were to
run one client instead of two, or to move them.

Moving them was chosen because it adds rather than removes. The lab gains two
sites, cross-region DNS and Kerberos, and a genuine reason for AD Sites and
Services, which a single flat subnet never needed. The constraint produced a better
architecture than the original plan had.

**Rejected: requesting a quota increase.** Not available on a free trial. Recorded
because it is the first thing a reader will think of.

**Rejected: one client instead of two.** Phase 6 needs a hardened machine beside an
untouched control, and Phase 7 needs two LAPS backends demonstrated side by side.
Dropping to one client would have cost both.

**Rejected: changing the VM size to fit another region.** `Standard_B2ls_v2` is
offered to this subscription in only three regions. Keeping the branch machines
identical to the HQ machines was worth more than a wider region choice, because a
size difference between sites would be an artefact of the trial rather than a
design decision.

**Given up.** The Phase 0 story of a single virtual network with no internet-facing
surface. There are now two peered networks, which is more moving parts and a small
continuous data transfer charge. Also auto-shutdown on the branch clients, since
Denmark East does not publish `Microsoft.DevTestLab`; they are deallocated by hand
instead, which is a cost control that depends on remembering.

---

## 13. Separate Terraform state for the branch, and a shared VM module

**Decision.** `terraform/azure-denmarkeast/` is its own root with its own state, not a folder
inside the HQ root. The VM resources are extracted into
`terraform/modules/windows-vm/`, consumed by the branch only.

**Why separate state.** Ownership, change cadence and recovery boundaries all
differ. The branch is meant to grow into unrelated work later, and a mistake there
should never be able to produce a plan that touches a promoted domain controller.

**The branch root owns both peering objects** and reads the HQ network through a
data source rather than remote state. The dependency runs one way: the branch knows
about HQ, HQ knows nothing about the branch, so the HQ root needed no changes at
all.

**Given up.** A clean state boundary. The branch root creates one resource, the
HQ-to-branch peering, inside the HQ resource group. Recorded rather than pretended
away; the alternative was making HQ depend on the branch existing, which is worse.

**Why a module for two callers, and why only one uses it.** The VM block is
genuinely reused, which meets the usual threshold. HQ was deliberately left on its
own inline copy: migrating it would need `moved` blocks pointing at DC01, and a
mistake there rebuilds the domain controller and costs Phases 1 and 2. The cost of
that choice is that the two can drift, so a fix in the module needs checking against
HQ by hand.

The module earns its place by encoding failures as validations rather than
comments. The 15-character computer name limit, the Arm64 sizes that will not boot
an x64 image, and the duplicate address that caused the Phase 0 apply failure are
all now plan-time errors.

---

## 14. Link at the OU, filter by security only where an OU must diverge

**Decision.** GPOs are linked to the OU that holds their target, and
`Authenticated Users` is left in place. Security filtering is used in exactly one
situation: when two objects sit in the same OU and must receive different policy.

Names describe the target rather than the setting, so `Workstation-Baseline` can
gain settings without the name going stale. The half of a GPO that holds nothing is
disabled, which stops it being evaluated and states the intent to the next reader.

**Rejected: filtering everything by security group.** It scales better in a large
estate, where OU structure is often owned by someone else and cannot be reshaped to
suit policy. It was rejected here because the effective scope of a GPO then lives
in an access control list rather than in the directory tree, and answering "what
applies to this machine" stops being something you can read off the OU. In a lab
whose OU structure was designed alongside the policy, that cost buys nothing.

**Where the exception is forced.** Phase 7 gives CL01 and CL02 different LAPS
backends while both sit in `OU=Workstations,OU=Sync`. Splitting them into separate
OUs to avoid filtering would be structure invented to dodge a mechanism rather than
to describe the organisation. `Loopback-Demo` in Phase 5 filters to CL02 alone for
the same reason and rehearses the same step.

**Given up.** The convention does not survive contact with an estate whose OU tree
is not yours to change. It also means the MS16-072 behaviour has to be understood
rather than avoided: since that update, policy is read in the computer's security
context, so a GPO filtered to a user group still needs `Authenticated Users` or
`Domain Computers` holding Read. `Set-GPPermission` warns about this before it acts
and cites [KB 3163622](https://support.microsoft.com/help/3163622).

**What is not scriptable.** `New-GPO`, `Set-GPRegistryValue`,
`New-NetFirewallRule -PolicyStore` and `New-GPLink` cover most of the estate. Group
Policy Preferences has no supported cmdlet, being XML in SYSVOL plus a client-side
extension registered on the GPO object, so anything delivered that way has to be
built in GPMC. Worth knowing before planning an estate around scripts.

---

## 15. Version-matched baseline, and one exception to it

**Decision.** Apply the Windows Server 2022 baseline to Server 2022 clients, import
only the Member Server GPO of the eight in the pack, and scope it to CL01 by security
filtering.

**Rejected: the Server 2025 baseline.** It is the prominent one on the download page
and would have applied without error. Settings referencing policies that do not exist
on Server 2022 never take effect, so they would surface as unexplained gaps in the
comparison. Every finding would then carry an asterisk about whether the setting was
absent or merely inapplicable.

**Rejected: rebuilding the clients on Server 2025 to match the newer baseline.** The
Terraform change is one variable. The cost is re-joining and re-hybrid-joining both
clients, and every Phase 4 and 5 screenshot showing build 20348 becoming wrong. Entry
11 records the same trade over renaming CS01, and it resolves the same way: weigh a
better configuration against invalidating your own evidence.

**One exception made, and its boundary.** The baseline sets SmartScreen to warn and
prevent bypass. On a machine that cannot reach the reputation service it fails closed,
which blocked Policy Analyzer from running on CL01. The fix was removing Mark of the
Web from that one binary rather than relaxing the setting.

Turning SmartScreen off would have been faster and wrong twice: the lab would lose a
control it had just deployed, and CL01 would no longer represent the baseline it was
being measured against.

**Given up.** The Server 2022 baseline is dated September 2021 and will age out. A
lab rebuilt later should track the OS, not this decision.

---

## 16. Group Policy Modeling instead of Policy Analyzer

**Decision.** Measure the baseline's effect with Group Policy Modeling reports rather
than Policy Analyzer exports.

Policy Analyzer is the tool Microsoft ships for this and the one Phase 6 was planned
around. Three things made it the wrong instrument here: it runs on the endpoint being
measured rather than centrally, its comparison and export steps are GUI-only with no
scriptable equivalent, and on the hardened client the baseline blocked it from
starting.

Modeling runs on the domain controller, needs nothing installed on either client,
names the winning GPO for every setting, and produces HTML that can be shared without
Excel.

**Given up.** Policy Analyzer compares against a machine's *effective state*, which
catches local configuration and drift that modeling does not see, since modeling
evaluates domain policy only. For a lab where nothing was set locally that difference
is theoretical. In an estate with real local configuration it would matter, and the
tool would earn its friction.

---

## 17. LAPS passwords encrypt to a Tier 1 group, not to Domain Admins

**Decision.** The authorized password decryptor is `SINDREDG\sg-it-admins`. CL01
backs up to Active Directory, CL02 to Entra ID. The managed account name is left
unset.

**Why the decryptor matters more than the ACL.** There are two independent gates.
`Set-LapsADReadPasswordPermission` writes a directory ACL controlling who can read
the attribute. The GPO's encryption principal controls who can decrypt its contents.
Granting the ACL to `sg-it-admins` while leaving the encryption principal at its
default would have quietly handed decryption back to Domain Admins, and the
least-privilege intent would have existed only on paper.

**Rejected: leaving the encryption principal unset.** The default is Domain Admins.
It works, and it makes the ACL decorative.

**The boundary is real and was verified.** Reading CL01's password as `labadmin`,
sole member of Domain Admins, returns the object with
`DecryptionStatus: Unauthorized`. Forest administration does not confer decryption.

**Its limit is worth stating.** A Domain Admin who cannot decrypt can still edit the
GPO, point the encryption principal at themselves and force a rotation. The boundary
constrains reading, not someone who can rewrite policy. It raises the cost and leaves
a trail; it is not a wall against the forest owner. Phase 8 is what narrows who holds
that position in the first place.

**Given up.** Encrypting to a group ties every stored password to that group's SID.
Delete `sg-it-admins` and recreate it and the existing encrypted passwords become
undecryptable. Not fatal, since any machine can be forced to rotate and write a fresh
one, but it is a real dependency that a plaintext or Domain-Admin-encrypted store
would not have.

**Which backend for which client.** CL01 to Active Directory because that is the
backend with the interesting access control story, and it is also the machine Phase 6
hardened. CL02 to Entra ID because it is the untouched control and its half is a
tenant role rather than a directory ACL. Running both is what makes the contrast
visible: the same question, "who may read a machine's local administrator password",
answered by a directory ACL plus an encryption principal on one side and by role
membership on the other.

**The account name is deliberately unset.** LAPS then manages the built-in
administrator, identified by RID 500 rather than by name. On these VMs Azure renamed
that account to `labadmin` rather than creating a second one, so the default targets
exactly the shared credential the risk register names. Setting the name explicitly
would have been redundant and would have broken if the account were ever renamed
again.

---

## Pending decisions

| Decision | Phase | Notes |
|---|---|---|
| Whether the GPO estate is exported into the repository | 7 | Bastion Basic offers no file transfer, so any export needs a storage account and a SAS. Deferred rather than half-built |
| Whether to bring CS01 under LAPS | 8 | It sits in `CN=Computers`, which no GPO can be linked to, so it needs moving into an OU. Phase 8 restructures OUs anyway |
| Whether to fold HQ into the shared VM module | 5 | Needs `moved` blocks against a promoted domain controller. Worth doing only on its own, with nothing else in the plan |
| Whether Phase 8 happens at all | 8 | Marked stretch. Phases 2 to 7 already tell a complete story |

