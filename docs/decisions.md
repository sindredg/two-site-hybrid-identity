# Decisions

Choices made during the build, the alternatives rejected, and what was given up.

---

## 1. Which tool owns which layer?

**Four tools, split by what each can actually do.**

| Layer | Tool | Why |
|---|---|---|
| Azure infrastructure | Terraform `azurerm` | Declarative, diffable, destroys cleanly |
| Forest, OUs, users, groups | PowerShell | Terraform cannot promote a forest at all |
| Endpoint configuration | Group Policy | The native mechanism, and the only one without Intune |
| Security baselines | Security Compliance Toolkit | Microsoft ships these as GPO backups, not as code |

*Why not `hashicorp/ad`?* Dormant since 0.5.0 in March 2024, and it needs WinRM to the domain
controller, which the Bastion-only design removes.

*Cost.* No plan and no drift detection for the directory layer. The scripts are idempotent, so
re-running is the drift check.

---

## 2. One Terraform root or two?

> **Superseded by entry 13.** There are two now. Kept because the reversal is the useful part.

**One, under `terraform/azure/`.**

`terraform/azure/` and `terraform/entra/` were split on blast-radius grounds: a bad Conditional
Access apply can lock every administrator out of a tenant, and that plan should not also be able
to rebuild a domain controller. Sound reasoning, empty root — the Entra layer here is wizard-
configured, and the Conditional Access that justified separate state is out of scope on
licensing. The nesting stayed because moving a root once state exists is disruptive.

*Cost.* None currently. The principle stands: separate state for anything whose worst-case
failure differs from the rest of the stack.

---

## 3. How do you reach the VMs?

**Azure Bastion Basic. No public IPs, and the host is gated behind `enable_bastion`.**

A public IP plus an NSG rule from one home address breaks silently whenever that address
rotates, and a domain controller should not publish RDP to the internet. `mstsc.exe` does not
exist on recent Windows 11 Home ARM64 builds, so RDP was unusable anyway.

*Why not Developer?* Free, so it went in first. It mostly failed to connect, and black-screened
then dropped when it did. The intermittency ruled out config and firewall, which fail
identically every time. Basic needs `AzureBastionSubnet` at `10.10.2.0/26` and a Standard static
public IP.

*Isn't it expensive?* $139/month is the 24/7 figure, and anchoring on it is what chose Developer.
Billing is hourly at $0.19 and Terraform destroys the host after a session.

*Cost.* A few dollars a month. `AzureBastionSubnet` must never carry the lab NSG — a partial
rule set breaks Bastion in ways that look like a VM fault.

---

## 4. Why is every private IP static?

**DC01 has to be, and the others have to be to stop them taking its address.**

DC01 is pinned to `10.10.1.4` because the VNet DNS setting needs a fixed address. Azure allocates
dynamic addresses from the lowest free one, which is `10.10.1.4`, and Terraform creates NICs in
parallel — a dynamic NIC won the race. See `troubleshooting/00-infrastructure.md`.

---

## 5. Which azurerm version?

**Pinned to `~> 4.2`, not 5.x.**

azurerm 5.0 changed the default `resource_provider_registration` from `legacy` to `none`. Where
`Microsoft.DevTestLab` was never registered, that breaks the auto-shutdown schedules with an
error that does not point at provider registration.

*Cost.* Newer resources and fixes in 5.x. Revisit by setting `resource_providers_to_register`
explicitly.

---

## 6. Server Core or Desktop Experience on DC01?

**Core.**

Desktop Experience would run on 4 GB, but Core is the correct habit for a domain controller:
smaller attack surface, fewer patches, less RAM spent on a GUI.

*Cost.* No local GUI tooling. Administration is PowerShell, or RSAT from CS01 once joined.

---

## 7. What is the forest called, and why doesn't the UPN suffix match?

**Forest `sindredg.local`, NetBIOS `SINDREDG`, UPN suffix `<tenant>.onmicrosoft.com`.**

The tenant's only verified domain is the onmicrosoft one, so the two are deliberately different.

*Why not a single-label domain?* A bare `sindredg` is unsupported by Microsoft and breaks Entra
Connect.

*Why not a routable domain like `sindredg.com`?* It would remove the retargeting step, but no
such domain is owned and a DNS TXT record cannot be added to prove one.

*Cost.* `.local` cannot be verified in Entra, so `@sindredg.local` users sync as
`@<tenant>.onmicrosoft.com` regardless. `03-prep-sync.ps1` adds the onmicrosoft suffix and
retargets the seed users first. That is the state a real `.local`-era environment is in before
its first sync, so the lab performs the remediation a migration would need.

---

## 8. Where does the lab stop, given no paid licences?

**At Conditional Access, not before synchronisation.**

P1 and P2 are unobtainable for this tenant. The instinct was to drop Entra ID entirely; checking
what actually needs a licence showed that was wider than necessary.

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

*Why not drop Entra entirely?* Briefly implemented. It discarded the two phases that make this
more than a generic Windows Server lab, for no licensing reason.

*Why not buy one P1?* Roughly $6 per user per month is affordable, but no paid licences were
available for this tenant at all.

*Why not write the policies without applying them?* Terraform that is never planned or applied
is unverifiable.

*Cost.* The device-based Conditional Access that would have tied hybrid join to an access
decision. `PLAN.md` names it as where the lab stops.

---

## 9. Connect Sync or Cloud Sync?

**Connect Sync, because Cloud Sync cannot do hybrid Entra join.**

Microsoft recommends Cloud Sync for new deployments. Device synchronization, which hybrid join
depends on, is supported only in Connect Sync.

| Capability | Connect Sync | Cloud Sync |
|---|---|---|
| Users, groups, contacts | Yes | Yes |
| Password hash sync | Yes | Yes |
| OU-based filtering | Yes | Yes |
| **Device synchronization** | **Yes** | **No** |
| **Hybrid Entra join** | **Yes** | **No** |
| Disconnected forests | No | Yes |
| Cloud-managed config | No | Yes |

*Cost.* An on-premises single point of failure, config living on that server rather than in the
cloud, and a product line Microsoft is steering away from. Acceptable against a hard requirement
Cloud Sync cannot meet.

---

## 10. Password Hash Sync or Pass-through Authentication?

**PHS.**

It keeps authentication working when the on-premises environment is unavailable, which for a lab
whose domain controller is deallocated most of the time is not hypothetical. It needs no
additional agents.

*Cost.* Password hashes leave the on-premises boundary, as a hash of a hash rather than the
password or the original hash. Where policy forbids that, PTA or federation is the answer.

---

## 11. How many machines, and why is CS01 still called CS01?

**Four. Two clients, so Phases 6 and 7 have a control.**

Phase 6 hardens CL01 and leaves CL02 untouched; Phase 7 points each at a different LAPS backend.
A second client is the cheapest way to turn an assertion into a comparison. Management runs from
CS01, not the DC — logging into a domain controller to run tooling makes a tiered model
meaningless before it starts.

*Why not rename CS01 to MGMT01?* Briefly implemented while Entra was out of scope, then reverted.
The name is accurate again now CS01 runs Connect Sync; the map key is the VM name, so a rename
replaces the VM, NIC, disk and shutdown schedule and orphans the AD computer object; and every
Phase 1 screenshot shows CS01. Rename while a machine is empty or not at all.

*Cost.* A fourth VM's standing disk, and a fifth that would have been a dedicated
privileged-access workstation for Phase 8. CS01 plays the Tier 1 box instead.

---

## 12. Why is the lab split across two regions?

**Sweden Central ran out of quota, so CL01 and CL02 moved to a second region, resource group and
state, joined by global VNet peering.**

A free trial caps Sweden Central at 4 vCPU on two separate counters, and DC01 and CS01 consume
all of it. Forced, then kept: the move added two sites, cross-region DNS and Kerberos, and a
genuine reason for AD Sites and Services.

*Why not raise the quota?* The normal answer, and not available on a free trial.

*Why not one client?* Phase 6 needs a hardened machine beside an untouched control, and Phase 7
needs two LAPS backends side by side.

*Why not resize to fit another region?* `Standard_B2ls_v2` is offered to this subscription in
only three. A size difference between sites would be an artefact of the trial rather than a
design decision.

*Cost.* More moving parts, a small data transfer charge, and no auto-shutdown on the branch
clients, since Denmark East does not publish `Microsoft.DevTestLab`.

---

## 13. How is the branch wired, and what is shared with HQ?

**Its own root and state at `terraform/azure-denmarkeast/`, with the VM resources extracted into
`terraform/modules/windows-vm/`.**

Ownership, change cadence and recovery boundaries all differ, and a mistake in the branch should
never produce a plan that touches a promoted domain controller. The branch root owns both peering
objects and reads the HQ network through a data source rather than remote state, so the
dependency runs one way and HQ needed no changes. The module encodes past failures as plan-time
validations: the 15-character computer name limit, Arm64 sizes that will not boot an x64 image,
and the duplicate address that broke the Phase 0 apply.

*Why does only one caller use the module?* Migrating HQ needs `moved` blocks pointing at DC01,
and a mistake there rebuilds the domain controller and costs Phases 1 and 2.

*Cost.* Not a clean state boundary — the branch root creates the HQ-to-branch peering inside the
HQ resource group. Making HQ depend on the branch existing is worse. The inline HQ copy can also
drift from the module.

---

## 14. How are GPOs scoped?

**Linked at the OU holding the target, with `Authenticated Users` left in place. Security
filtering only when two objects in the same OU must receive different policy.**

Names describe the target rather than the setting, so `Workstation-Baseline` can gain settings
without going stale. The unused half of a GPO is disabled.

*Why not filter everything by security group?* It scales better where someone else owns the OU
structure, but a GPO's effective scope then lives in an access control list, and "what applies to
this machine" stops being readable off the directory tree.

*Where is the exception forced?* Phase 7 gives CL01 and CL02 different LAPS backends inside
`OU=Workstations,OU=Sync`. Separate OUs would be structure invented to dodge a mechanism.
`Loopback-Demo` in Phase 5 filters to CL02 alone for the same reason.

*Cost.* MS16-072 has to be understood rather than avoided: policy is read in the computer's
security context, so a GPO filtered to a user group still needs `Authenticated Users` or
`Domain Computers` holding Read. `Set-GPPermission` cites
[KB 3163622](https://support.microsoft.com/help/3163622).

*What is not scriptable?* Group Policy Preferences — XML in SYSVOL plus a client-side extension
registered on the GPO object, with no supported cmdlet. Everything else is `New-GPO`,
`Set-GPRegistryValue`, `New-NetFirewallRule -PolicyStore` and `New-GPLink`.

---

## 15. Which security baseline, and was it applied whole?

**Windows Server 2022, matching the clients. The Member Server GPO only, filtered to CL01.**

*Why not the Server 2025 baseline?* It is the prominent download and would apply without error,
but settings referencing policies that do not exist on Server 2022 never take effect. They would
surface as unexplained gaps and every finding would carry an asterisk.

*Why not rebuild the clients on Server 2025?* One Terraform variable, but it costs re-joining and
re-hybrid-joining both clients and invalidates every Phase 4 and 5 screenshot showing build 20348.

*What was excepted?* The baseline sets SmartScreen to warn and prevent bypass, which fails closed
on a machine that cannot reach the reputation service and blocked Policy Analyzer on CL01. Mark of
the Web was removed from that one binary instead — turning SmartScreen off would have left CL01
no longer representing the baseline it was measured against.

*Cost.* The Server 2022 baseline is dated September 2021 and will age out.

---

## 16. How is the baseline's effect measured?

**Group Policy Modeling reports, not Policy Analyzer exports.**

Policy Analyzer is the tool Microsoft ships for this, but it runs on the endpoint being measured
rather than centrally, its comparison and export steps are GUI-only, and on the hardened client
the baseline blocked it from starting. Modeling runs on the domain controller, needs nothing
installed, names the winning GPO for every setting, and produces shareable HTML.

*Cost.* Policy Analyzer compares against a machine's *effective state*, catching local
configuration and drift that modeling cannot see. Theoretical in this lab, real in an estate.

---

## 17. Who can read a machine's LAPS password?

**`SINDREDG\sg-it-admins`, not Domain Admins. CL01 backs up to Active Directory, CL02 to Entra
ID, and the managed account name is left unset.**

Two independent gates: `Set-LapsADReadPasswordPermission` writes the directory ACL controlling
who can read the attribute, and the GPO's encryption principal controls who can decrypt it.
Setting the ACL while leaving the principal at its default would quietly hand decryption back to
Domain Admins. Verified — reading CL01's password as `labadmin`, sole Domain Admin, returns
`DecryptionStatus: Unauthorized`.

*Why a different backend per client?* CL01 to Active Directory, the backend with the interesting
access control story and the machine Phase 6 hardened. CL02 to Entra ID, where the equivalent
gate is a tenant role rather than a directory ACL.

*Why is the account name unset?* LAPS then manages the built-in administrator by RID 500 rather
than by name. Azure renamed that account to `labadmin`, so the default targets exactly the shared
credential the risk register names.

*Where does it stop?* A Domain Admin who cannot decrypt can still edit the GPO, point the
encryption principal at themselves and force a rotation. It constrains reading, not policy
rewriting. Phase 8 narrows who holds that position.

*Cost.* Encryption ties every stored password to the group's SID. Delete and recreate
`sg-it-admins` and existing passwords become undecryptable — recoverable by forcing a rotation,
but a real dependency.

---

## 18. Why is Tier 0 missing from Entra ID?

**Admin accounts and `sg-tier0-admins` sit under `OU=Admin,OU=NoSync`, not beside the other `sg-`
groups in `OU=Groups,OU=Sync`.**

Sync is scoped to `OU=Sync`. A privileged on-premises account with a cloud object is a second
attack path onto the same credential, so no tier account syncs. Tier 0 goes further: neither the
group nor its member exists in the tenant at all, so a compromised tenant has nothing to find.

*Why not keep all `sg-` groups together?* Consistent naming, and a Tier 0 group in the cloud for
no operational benefit. `sg-it-admins` and `sg-helpdesk` do sync, so `t1-admin` joining
`sg-it-admins` produces a synced group whose member is out of scope — the clearest illustration
of what OU scoping does.

*Cost.* A reader scanning the OU tree sees three `sg-` groups in one place and one in another.
That is why this entry exists.

---

## 19. Do deny rules name groups or accounts?

**Groups. No individual account appears in any of the three GPOs.**

Deny rights are evaluated against every SID in the access token, and group memberships are in the
token. Naming the group covers its members, and an account added to a tier later is covered
without editing a GPO.

*Why not name both?* The first pass listed `sg-it-admins` and `t1-admin` side by side, as some
real tiered builds do against someone being removed from a group. It doubles the maintenance and,
with one account per tier, buys nothing.

*Cost.* Tier membership is now purely group membership, so removing an account from a group
silently removes its restriction as well as its access.

---

## 20. Which logon types are denied where?

**All five on the Tier 1 and Tier 2 GPOs. Interactive and Remote Desktop only on Tier 0.**

*Why omit network logon on domain controllers?* A DC is also the SYSVOL file server every member
reads Group Policy from and the LDAP endpoint RSAT on CS01 talks to. Denying it for Tier 1 and
Tier 2 breaks both. Microsoft's guidance includes it because those accounts have no such need in
an estate with dedicated management hosts.

*Why keep it downward?* A Tier 0 credential that cannot make a network logon to a workstation
cannot be replayed from one, and Tier 0 has no work to do there.

*Cost.* A Tier 1 or Tier 2 credential can still reach a domain controller over the network. A
real gap, accepted because closing it breaks the lab's only management path.

*What could not be demonstrated?* The network denial on the clients. `net use \\CL01\C$` returns
`System error 53`, because the Phase 6 baseline firewall drops SMB before the right is reached.

---

## 21. How is local Administrators controlled?

**Group Policy Preferences, Local Users and Groups, action Update, both delete checkboxes clear.
Each tier GPO also names the other tier's group with Remove from this group.**

*Why not Restricted Groups?* Its *Members of this group* list replaces membership wholesale,
stripping `Domain Admins` from every machine in scope. Preferences offers the same behaviour
behind the delete checkboxes, but off by default rather than on.

*Why the explicit Remove?* Preferences do not revert. Dropping a member from the item stops it
being added again but leaves it on machines that already have it, so local Administrators is
additive only and a machine that acquires a wrong administrator keeps it.

*Cost.* `Domain Admins` is deliberately not in either Remove list. Tier 0 on a lower-tier machine
is handled by the deny-logon rights, which make its local membership irrelevant.

---

## 22. Why does a tier GPO carry baseline settings?

**`Tier2-Logon-Restrictions` links at `OU=Workstations` at link order 1 and carries `S-1-5-113`
and `S-1-5-114` forward from `Baseline-MemberServer-2022`.**

User Rights Assignment does not merge across GPOs. The higher-precedence GPO supplies the entire
member list for a right and the other's entries stop existing, so without carrying them the Phase
6 result that CL01 refuses the shared local administrator over Bastion silently reverts.

*Why not split `OU=Workstations` into hardened and control sub-OUs?* It preserves both cleanly,
but that OU's distinguished name appears in Phases 5, 6 and 7 including the LAPS ACLs.

*Why not leave RDP and network denies out of the tier model?* It keeps CL02 pristine and removes
the control against a Tier 0 credential being replayed from a workstation, which is the most
valuable thing the phase does.

*Cost.* The baseline is filtered to CL01 and the tier GPO is not, so CL02 gains those two
settings. From Phase 8 onward it is a control for everything in the baseline *except* them.

---

## 23. What happens to `labadmin`?

**Retired to break-glass, not stripped: same memberships, a new password held outside the
repository and outside Terraform, a description saying what it is for, and no routine use. It is
named in no deny rule, so it reaches every machine.**

It is RID 500 — it cannot be deleted, cannot be locked out by policy, and still works when
Kerberos, DNS or a Group Policy change have broken everything else. A tier model with no exempt
account has no recovery path, and this phase needed one twice.

*Cost.* A single credential still exists which, if stolen, defeats the whole model, and nothing
enforces that it stays unused. Risk register entry 12.

*Where does the argument stop?* One layer up, unsolved. Azure `run-command` executes as SYSTEM
with no logon, so subscription rights are forest rights regardless of anything in this document.
Risk register entry 10.

---

## Pending decisions

| Decision | Phase | Notes |
|---|---|---|
| Whether the GPO estate is exported into the repository | 7 | Bastion Basic offers no file transfer, so any export needs a storage account and a SAS. Deferred rather than half-built. Phase 8 added five more GPOs to an estate that exists only inside the lab |
| Whether to fold HQ into the shared VM module | 5 | Needs `moved` blocks against a promoted domain controller. Worth doing only on its own |
| Whether to add a second member to `sg-it-admins` | 8 | It is now a single account and the encryption principal for two machines' LAPS passwords. Recoverable, since encryption is to the group SID, but a single point of failure |
| Whether a Tier 0 administrative workstation is worth a fifth VM | 8 | Without one, Group Policy editing falls back to `labadmin`, because `t0-admin` cannot sign into the machine GPMC runs on |
