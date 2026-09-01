# Architecture decisions

Decisions are grouped by domain. Each entry records what was chosen, why, what was
rejected, and what the choice costs.

## Tooling and state

### Which tool owns which layer

**Decision:** Four tools, split by what each can actually do.

| Layer | Tool | Why |
|---|---|---|
| Azure infrastructure | Terraform `azurerm` | Declarative, diffable, destroys cleanly |
| Forest, OUs, users, groups | PowerShell | Terraform cannot promote a forest at all |
| Endpoint configuration | Group Policy | The native mechanism, and the only one without Intune |
| Security baselines | Security Compliance Toolkit | Microsoft ships these as GPO backups, not as code |

**Alternatives:** The `hashicorp/ad` provider, which would have put the directory layer under
Terraform too. Dormant since 0.5.0 in March 2024, and it needs WinRM to the domain controller,
which the Bastion-only design removes.

**Trade-off:** No plan and no drift detection for the directory layer. The scripts are
idempotent, so re-running is the drift check.

### Terraform root layout

> **Note:** Superseded by [Branch state and the shared VM module](#branch-state-and-the-shared-vm-module).
> There are two roots now. The entry is kept because the reversal is the useful part.

**Decision:** One root, under `terraform/azure/`.

**Why:** `terraform/azure/` and `terraform/entra/` were split on blast-radius grounds: a bad
Conditional Access apply can lock every administrator out of a tenant, and that plan should not
also be able to rebuild a domain controller. Sound reasoning, empty root — the Entra layer here
is wizard-configured, and the Conditional Access that justified separate state is out of scope
on licensing. The nesting stayed because moving a root once state exists is disruptive.

**Trade-off:** None at the time. The principle stands: separate state for anything whose
worst-case failure differs from the rest of the stack.

### Branch state and the shared VM module

**Decision:** The branch gets its own root and state at `terraform/azure-denmarkeast/`, with the
VM resources extracted into `terraform/modules/windows-vm/`.

**Why:** Ownership, change cadence and recovery boundaries all differ, and a mistake in the
branch should never produce a plan that touches a promoted domain controller. The branch root
owns both peering objects and reads the HQ network through a data source rather than remote
state, so the dependency runs one way and HQ needed no changes. The module encodes past failures
as plan-time validations: the 15-character computer name limit, Arm64 sizes that will not boot an
x64 image, and the duplicate address that broke the Phase 0 apply.

**Alternatives:** Migrating HQ onto the module as well. That needs `moved` blocks pointing at
DC01, and a mistake there rebuilds the domain controller and costs Phases 1 and 2.

**Trade-off:** Not a clean state boundary — the branch root creates the HQ-to-branch peering
inside the HQ resource group. Making HQ depend on the branch existing is worse. The inline HQ
copy can also drift from the module.

### Provider version

**Decision:** `azurerm` pinned to `~> 4.2`, not 5.x.

**Why:** azurerm 5.0 changed the default `resource_provider_registration` from `legacy` to
`none`. Where `Microsoft.DevTestLab` was never registered, that breaks the auto-shutdown
schedules with an error that does not point at provider registration.

**Trade-off:** Newer resources and fixes in 5.x. Revisit by setting
`resource_providers_to_register` explicitly.

## Networking and access

### Reaching the VMs

**Decision:** Azure Bastion Basic. No public IPs, and the host is gated behind `enable_bastion`.

**Why:** A public IP plus an NSG rule from one home address breaks silently whenever that address
rotates, and a domain controller should not publish RDP to the internet. `mstsc.exe` does not
exist on recent Windows 11 Home ARM64 builds, so RDP was unusable anyway. The $139/month figure
quoted for Basic is the 24/7 rate, and anchoring on it is what chose Developer first; billing is
hourly at $0.19 and Terraform destroys the host after a session.

**Alternatives:** The Developer SKU, which is free and went in first. It mostly failed to
connect, and black-screened then dropped when it did. The intermittency ruled out config and
firewall, which fail identically every time. Basic needs `AzureBastionSubnet` at `10.10.2.0/26`
and a Standard static public IP.

**Trade-off:** A few dollars a month. `AzureBastionSubnet` must never carry the lab NSG — a
partial rule set breaks Bastion in ways that look like a VM fault.

### Static private IPs

**Decision:** Every private IP is static.

**Why:** DC01 is pinned to `10.10.1.4` because the VNet DNS setting needs a fixed address. Azure
allocates dynamic addresses from the lowest free one, which is `10.10.1.4`, and Terraform creates
NICs in parallel, so a dynamic NIC won the race. The others are static to stop them taking DC01's
address. See [troubleshooting/00-infrastructure.md](troubleshooting/00-infrastructure.md).

### Two regions

**Decision:** Sweden Central ran out of quota, so CL01 and CL02 moved to a second region,
resource group and state, joined by global VNet peering.

**Why:** A free trial caps Sweden Central at 4 vCPU on two separate counters, and DC01 and CS01
consume all of it. Forced, then kept: the move added two sites, cross-region DNS and Kerberos,
and a genuine reason for AD Sites and Services.

**Alternatives:** Raising the quota, which is the normal answer and is not available on a free
trial. Dropping to one client, which Phase 6 rules out because it needs a hardened machine beside
an untouched control, and Phase 7 rules out because it needs two LAPS backends side by side.
Resizing to fit another region, which fails because `Standard_B2ls_v2` is offered to this
subscription in only three, and a size difference between sites would be an artifact of the trial
rather than a design decision.

**Trade-off:** More moving parts, a small data transfer charge, and no auto-shutdown on the
branch clients, since Denmark East does not publish `Microsoft.DevTestLab`.

## Directory

### Domain controller operating system

**Decision:** Server 2022 Core on DC01.

**Why:** Desktop Experience would run on 4 GB, but Core is the correct habit for a domain
controller: smaller attack surface, fewer patches, less RAM spent on a GUI.

**Trade-off:** No local GUI tooling. Administration is PowerShell, or RSAT from CS01 once joined.

### Forest name and UPN suffix

**Decision:** Forest `sindredg.local`, NetBIOS `SINDREDG`, UPN suffix
`<tenant>.onmicrosoft.com`. The two are deliberately different, because the tenant's only
verified domain is the onmicrosoft one.

**Alternatives:** A single-label domain. A bare `sindredg` is unsupported by Microsoft and breaks
Entra Connect. A routable domain such as `sindredg.com` would remove the retargeting step, but no
such domain is owned and a DNS TXT record cannot be added to prove one.

**Trade-off:** `.local` cannot be verified in Entra, so `@sindredg.local` users sync as
`@<tenant>.onmicrosoft.com` regardless. `03-prep-sync.ps1` adds the onmicrosoft suffix and
retargets the seed users first. That is the state a real `.local`-era environment is in before
its first sync, so the lab performs the remediation a migration would need.

### Machine count and naming

**Decision:** Four machines. Two clients, so Phases 6 and 7 have a control. CS01 keeps its name.

**Why:** Phase 6 hardens CL01 and leaves CL02 untouched; Phase 7 points each at a different LAPS
backend. A second client is the cheapest way to turn an assertion into a comparison. Management
runs from CS01, not the DC — logging into a domain controller to run tooling makes a tiered model
meaningless before it starts.

**Alternatives:** Renaming CS01 to MGMT01, briefly implemented while Entra was out of scope, then
reverted. The name is accurate again now CS01 runs Connect Sync; the map key is the VM name, so a
rename replaces the VM, NIC, disk and shutdown schedule and orphans the AD computer object; and
every Phase 1 screenshot shows CS01. Rename while a machine is empty or not at all.

**Trade-off:** A fourth VM's standing disk, and a fifth that would have been a dedicated
privileged-access workstation for Phase 8. CS01 plays the Tier 1 box instead.

## Identity and synchronization

### Where the lab stops on licensing

**Decision:** At Conditional Access, not before synchronization.

**Why:** P1 and P2 are unobtainable for this tenant. The instinct was to drop Entra ID entirely;
checking what actually needs a license showed that was wider than necessary.

| Capability | License | Available here |
|---|---|---|
| Entra Connect Sync, PHS, OU filtering | None | Yes |
| Hybrid Entra join | None | Yes |
| Seamless SSO | None | Yes |
| Windows LAPS, backup to Active Directory | None | Yes |
| Windows LAPS, backup to Entra ID | Entra ID Free | Yes |
| Conditional Access | P1 | No |
| PIM, access reviews, Identity Protection | P2 | No |
| Password writeback, group writeback, Connect Health | P1 | No |

**Alternatives:** Dropping Entra entirely, briefly implemented. It discarded the two phases that
make this more than a generic Windows Server lab, for no licensing reason. Buying a single P1, at
roughly $6 per user per month, which is affordable but was not available for this tenant at all.
Writing the policies without applying them, which is unverifiable: Terraform that is never planned
or applied proves nothing.

**Trade-off:** The device-based Conditional Access that would have tied hybrid join to an access
decision. [PLAN.md](PLAN.md) names it as where the lab stops.

### Connect Sync or Cloud Sync

**Decision:** Connect Sync, because Cloud Sync cannot do hybrid Entra join.

**Why:** Microsoft recommends Cloud Sync for new deployments. Device synchronization, which
hybrid join depends on, is supported only in Connect Sync.

| Capability | Connect Sync | Cloud Sync |
|---|---|---|
| Users, groups, contacts | Yes | Yes |
| Password hash sync | Yes | Yes |
| OU-based filtering | Yes | Yes |
| **Device synchronization** | **Yes** | **No** |
| **Hybrid Entra join** | **Yes** | **No** |
| Disconnected forests | No | Yes |
| Cloud-managed config | No | Yes |

**Trade-off:** An on-premises single point of failure, config living on that server rather than in
the cloud, and a product line Microsoft is steering away from. Acceptable against a hard
requirement Cloud Sync cannot meet.

### Password hash sync or pass-through authentication

**Decision:** Password hash sync.

**Why:** It keeps authentication working when the on-premises environment is unavailable, which
for a lab whose domain controller is deallocated most of the time is not hypothetical. It needs no
additional agents.

**Alternatives:** Pass-through authentication or federation, which is the answer where policy
forbids hashes leaving the on-premises boundary.

**Trade-off:** Password hashes leave the on-premises boundary, as a hash of a hash rather than the
password or the original hash.

## Group Policy

### How GPOs are scoped

**Decision:** Linked at the OU holding the target, with `Authenticated Users` left in place.
Security filtering only when two objects in the same OU must receive different policy.

**Why:** Names describe the target rather than the setting, so `Workstation-Baseline` can gain
settings without going stale. The unused half of a GPO is disabled. The exception is forced in
Phase 7, which gives CL01 and CL02 different LAPS backends inside `OU=Workstations,OU=Sync`;
separate OUs would be structure invented to dodge a mechanism. `Loopback-Demo` in Phase 5 filters
to CL02 alone for the same reason.

**Alternatives:** Filtering everything by security group. It scales better where someone else owns
the OU structure, but a GPO's effective scope then lives in an access control list, and "what
applies to this machine" stops being readable off the directory tree.

**Trade-off:** MS16-072 has to be understood rather than avoided: policy is read in the computer's
security context, so a GPO filtered to a user group still needs `Authenticated Users` or
`Domain Computers` holding Read. `Set-GPPermission` cites
[KB 3163622](https://support.microsoft.com/help/3163622). Group Policy Preferences are also not
scriptable — XML in SYSVOL plus a client-side extension registered on the GPO object, with no
supported cmdlet. Everything else is `New-GPO`, `Set-GPRegistryValue`,
`New-NetFirewallRule -PolicyStore` and `New-GPLink`.

## Security baselines

### Which baseline, and how much of it

**Decision:** The Windows Server 2022 baseline, matching the clients. The Member Server GPO only,
filtered to CL01.

**Alternatives:** The Server 2025 baseline, which is the prominent download and would apply
without error, but settings referencing policies that do not exist on Server 2022 never take
effect; they would surface as unexplained gaps and every finding would carry an asterisk.
Rebuilding the clients on Server 2025, which is one Terraform variable but costs re-joining and
re-hybrid-joining both clients and invalidates every Phase 4 and 5 screenshot showing build 20348.

**Trade-off:** One exception was needed. The baseline sets SmartScreen to warn and prevent bypass,
which fails closed on a machine that cannot reach the reputation service and blocked Policy
Analyzer on CL01. Mark of the Web was removed from that one binary instead — turning SmartScreen
off would have left CL01 no longer representing the baseline it was measured against. The Server
2022 baseline is also dated September 2021 and will age out.

### Measuring the baseline's effect

**Decision:** Group Policy Modeling reports, not Policy Analyzer exports.

**Why:** Modeling runs on the domain controller, needs nothing installed, names the winning GPO
for every setting, and produces shareable HTML.

**Alternatives:** Policy Analyzer, the tool Microsoft ships for this. It runs on the endpoint being
measured rather than centrally, its comparison and export steps are GUI-only, and on the hardened
client the baseline blocked it from starting.

**Trade-off:** Policy Analyzer compares against a machine's *effective state*, catching local
configuration and drift that modeling cannot see. Theoretical in this lab, real in an estate.

## Windows LAPS

### Who can read a machine's password

**Decision:** `SINDREDG\sg-it-admins`, not Domain Admins. CL01 backs up to Active Directory, CL02
to Entra ID, and the managed account name is left unset.

**Why:** Two independent gates: `Set-LapsADReadPasswordPermission` writes the directory ACL
controlling who can read the attribute, and the GPO's encryption principal controls who can
decrypt it. Setting the ACL while leaving the principal at its default would quietly hand
decryption back to Domain Admins. Verified — reading CL01's password as `labadmin`, sole Domain
Admin, returns `DecryptionStatus: Unauthorized`.

A different backend per client is deliberate: CL01 to Active Directory, the backend with the
interesting access control story and the machine Phase 6 hardened; CL02 to Entra ID, where the
equivalent gate is a tenant role rather than a directory ACL. The account name is unset so LAPS
manages the built-in administrator by RID 500 rather than by name. Azure renamed that account to
`labadmin`, so the default targets exactly the shared credential the risk register names.

**Trade-off:** This constrains reading, not policy rewriting. A Domain Admin who cannot decrypt can
still edit the GPO, point the encryption principal at themselves and force a rotation; the tier
model narrows who holds that position. Encryption also ties every stored password to the group's
SID, so deleting and recreating `sg-it-admins` makes existing passwords undecryptable —
recoverable by forcing a rotation, but a real dependency.

## Tiered administration

### Tier 0 outside Entra ID

**Decision:** Admin accounts and `sg-tier0-admins` sit under `OU=Admin,OU=NoSync`, not beside the
other `sg-` groups in `OU=Groups,OU=Sync`.

**Why:** Sync is scoped to `OU=Sync`. A privileged on-premises account with a cloud object is a
second attack path onto the same credential, so no tier account syncs. Tier 0 goes further:
neither the group nor its member exists in the tenant at all, so a compromised tenant has nothing
to find.

**Alternatives:** Keeping all `sg-` groups together, for consistent naming, which puts a Tier 0
group in the cloud for no operational benefit. `sg-it-admins` and `sg-helpdesk` do sync, so
`t1-admin` joining `sg-it-admins` produces a synced group whose member is out of scope — the
clearest illustration of what OU scoping does.

**Trade-off:** A reader scanning the OU tree sees three `sg-` groups in one place and one in
another. That is why this entry exists.

### Groups, not accounts, in deny rules

**Decision:** Groups. No individual account appears in any of the three GPOs.

**Why:** Deny rights are evaluated against every SID in the access token, and group memberships are
in the token. Naming the group covers its members, and an account added to a tier later is covered
without editing a GPO.

**Alternatives:** Naming both. The first pass listed `sg-it-admins` and `t1-admin` side by side, as
some real tiered builds do against someone being removed from a group. It doubles the maintenance
and, with one account per tier, buys nothing.

**Trade-off:** Tier membership is now purely group membership, so removing an account from a group
silently removes its restriction as well as its access.

### Which logon types are denied where

**Decision:** All five on the Tier 1 and Tier 2 GPOs. Interactive and Remote Desktop only on
Tier 0.

**Why:** A domain controller is also the SYSVOL file server every member reads Group Policy from
and the LDAP endpoint RSAT on CS01 talks to, so denying network logon for Tier 1 and Tier 2 breaks
both. Microsoft's guidance includes it because those accounts have no such need in an estate with
dedicated management hosts. Downward it is kept: a Tier 0 credential that cannot make a network
logon to a workstation cannot be replayed from one, and Tier 0 has no work to do there.

**Trade-off:** A Tier 1 or Tier 2 credential can still reach a domain controller over the network.
A real gap, accepted because closing it breaks the lab's only management path. The network denial
on the clients could also not be demonstrated: `net use \\CL01\C$` returns `System error 53`,
because the Phase 6 baseline firewall drops SMB before the right is reached.

### How local Administrators is controlled

**Decision:** Group Policy Preferences, Local Users and Groups, action Update, both delete
checkboxes clear. Each tier GPO also names the other tier's group with Remove from this group.

**Why:** Preferences do not revert. Dropping a member from the item stops it being added again but
leaves it on machines that already have it, so local Administrators is additive only and a machine
that acquires a wrong administrator keeps it. The explicit Remove is what closes that.

**Alternatives:** Restricted Groups. Its *Members of this group* list replaces membership
wholesale, stripping `Domain Admins` from every machine in scope. Preferences offers the same
behavior behind the delete checkboxes, but off by default rather than on.

**Trade-off:** `Domain Admins` is deliberately not in either Remove list. Tier 0 on a lower-tier
machine is handled by the deny-logon rights, which make its local membership irrelevant.

### Why a tier GPO carries baseline settings

**Decision:** `Tier2-Logon-Restrictions` links at `OU=Workstations` at link order 1 and carries
`S-1-5-113` and `S-1-5-114` forward from `Baseline-MemberServer-2022`.

**Why:** User Rights Assignment does not merge across GPOs. The higher-precedence GPO supplies the
entire member list for a right and the other's entries stop existing, so without carrying them the
Phase 6 result that CL01 refuses the shared local administrator over Bastion silently reverts.

**Alternatives:** Splitting `OU=Workstations` into hardened and control sub-OUs, which preserves
both cleanly, but that OU's distinguished name appears in Phases 5, 6 and 7 including the LAPS
ACLs. Leaving RDP and network denies out of the tier model, which keeps CL02 pristine and removes
the control against a Tier 0 credential being replayed from a workstation — the most valuable
thing the phase does.

**Trade-off:** The baseline is filtered to CL01 and the tier GPO is not, so CL02 gains those two
settings. From Phase 8 onward it is a control for everything in the baseline *except* them.

### What happens to `labadmin`

**Decision:** Retired to break-glass, not stripped: same memberships, a new password held outside
the repository and outside Terraform, a description saying what it is for, and no routine use. It
is named in no deny rule, so it reaches every machine.

**Why:** It is RID 500 — it cannot be deleted, cannot be locked out by policy, and still works when
Kerberos, DNS or a Group Policy change have broken everything else. A tier model with no exempt
account has no recovery path, and this phase needed one twice.

**Trade-off:** A single credential still exists which, if stolen, defeats the whole model, and
nothing enforces that it stays unused. See
[risk register entry 12](risk-and-limitations.md#12-labadmin-is-exempt-from-every-deny-rule). The
argument also stops one layer up, unsolved: Azure `run-command` executes as SYSTEM with no logon,
so subscription rights are forest rights regardless of anything in this document. See
[risk register entry 10](risk-and-limitations.md#10-the-azure-control-plane-is-an-unreduced-path-to-tier-0).

## Deferred decisions

| Decision | Phase | Notes |
|---|---|---|
| Whether the GPO estate is exported into the repository | 7 | Bastion Basic offers no file transfer, so any export needs a storage account and a SAS. Deferred rather than half-built. Phase 8 added five more GPOs to an estate that exists only inside the lab |
| Whether to fold HQ into the shared VM module | 5 | Needs `moved` blocks against a promoted domain controller. Worth doing only on its own |
| Whether to add a second member to `sg-it-admins` | 8 | It is now a single account and the encryption principal for two machines' LAPS passwords. Recoverable, since encryption is to the group SID, but a single point of failure |
| Whether a Tier 0 administrative workstation is worth a fifth VM | 8 | Without one, Group Policy editing falls back to `labadmin`, because `t0-admin` cannot sign into the machine GPMC runs on |
