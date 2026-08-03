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
| Endpoint configuration | Group Policy, backed up to XML | The native mechanism. `Backup-GPO` puts the estate in the repo rather than only in SYSVOL |
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
the race and took the DC's address. See `99-troubleshooting.md`.

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
domain is `sindredemitriohotmail.onmicrosoft.com`, so the on-prem domain and the
UPN suffix are deliberately different.

**Rejected: a single-label domain.** A bare `sindredg` with no suffix is
unsupported by Microsoft and breaks Entra Connect.

**Rejected: a routable domain such as `sindredg.com`.** It would let the on-prem
suffix match a verified Entra domain, removing the retargeting step entirely.
Not available, because no such domain is owned and a DNS TXT record cannot be
added to prove it.

**Given up.** `.local` cannot be verified in Entra, so users created with a
`@sindredg.local` UPN would sync as `@sindredemitriohotmail.onmicrosoft.com`
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

**Two clients, not one.** Phase 5 applies a security baseline to CL01 and leaves
CL02 untouched as a control, so Policy Analyzer has something to compare against.
Phase 6 then points each at a different LAPS backend, one to Active Directory and
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
dedicated privileged-access workstation for Phase 7. CS01 plays the Tier 1 box
instead.

---

## Pending decisions

| Decision | Phase | Notes |
|---|---|---|
| Whether computer objects sync | 3 | Hybrid join needs them. They are already inside `OU=Sync`, but the Connect Sync scope has to include them explicitly and excluding them fails in a way that is hard to diagnose |
| GPO naming and linking convention | 4 | OU linking is simpler to reason about; security-group filtering scales better and is harder to audit |
| How far to take the security baseline | 5 | Applying Microsoft's baseline wholesale will break something. The exceptions and their reasons belong here as they are decided |
| Which LAPS backend for which client | 6 | Currently CL01 to Active Directory, CL02 to Entra ID. Worth confirming once both are hybrid-joined, since a device can use one or the other but not both |
| Who can decrypt LAPS passwords | 6 | The forest supports encryption. Which group holds decryption rights is the actual security decision, not whether to enable it |
| Whether Phase 7 happens at all | 7 | Marked stretch. Phases 2 to 6 already tell a complete story |

