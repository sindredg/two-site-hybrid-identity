# Roadmap

Phases ordered by dependency, not preference. Each is blocked by the one above it,
and each states what "done" means so progress is checkable rather than asserted.

Status legend: Completed, In progress, Pending, Blocked.

---

## Phase 0. Azure infrastructure: Completed

Resource group `rg-hybridid-swedencentral`. VNet, subnet, NSG, Bastion, and the
VMs with their NICs, disks and auto-shutdown schedules. All Terraform, in
`terraform/azure/`. Walkthrough in `docs/00-infrastructure.md`.

| Delivered | Detail |
|---|---|
| No internet-facing surface | Public IPs removed, single inbound NSG rule scoped to `VirtualNetwork` |
| Bastion access | Developer SKU, free, browser-based |
| Static private IPs | DC01 `.4`, CS01 `.5`, CL01 `.6` |
| Cost control | Daily auto-shutdown, CL01 gated behind `enable_client` |

**Exit criteria met.** `terraform plan -detailed-exitcode` returns 0 against the
deployed environment.

---

## Phase 1. AD environment: In progress

**Goal.** A working forest with a directory structure realistic enough that
scoped synchronisation is a meaningful thing to demonstrate.

1. Promote DC01 to a new forest and install DNS. `scripts/ad-bootstrap/01-promote-dc.ps1`
2. Point the VNet at the DC: set `dns_servers = ["10.10.1.4"]` in
   `terraform/terraform.tfvars`, re-apply, then reboot CS01
3. Join CS01 to the domain
4. Create OUs, security groups and seed users. `scripts/ad-bootstrap/02-ad-structure.ps1`
5. Add a routable UPN suffix and pre-flight for sync. `scripts/ad-bootstrap/03-prep-sync.ps1`

**Step 2 is the one people skip.** Azure-provided DNS cannot resolve an AD domain,
so the join fails with a "domain not found" message that reads like a credentials
problem. The VNet DNS change also needs a reboot before a VM picks it up, because
the NIC only re-reads DHCP on restart.

**Exit criteria.** CS01 domain-joined; seeded users present with routable UPNs; no
duplicate `proxyAddresses`; `dcdiag` clean.

---

## Phase 2. Entra Connect Sync: Blocked on licensing

**Blocker.** The tenant has zero subscribed SKUs. Conditional Access requires
Entra ID P1, PIM and access reviews require P2. Start the P2 trial before this
phase, not during it.

1. Verify a custom domain in Entra, match the on-prem UPN suffix to it
2. Install Entra Connect Sync on CS01: Password Hash Sync, filtering scoped to
   `OU=Sync`
3. Force a delta sync, confirm seeded users land in Entra
4. Record the decisions in an ADR: PHS over PTA, filtering scope, and why

Scoping the sync to one OU rather than the whole directory is the point of the
`Sync` and `NoSync` split created in Phase 1. Syncing everything would work and
demonstrate nothing.

**Exit criteria.** On-prem users visible in Entra with `onPremisesSyncEnabled`
true, sync errors at zero.

---

## Phase 3. Hybrid join: Blocked on Phase 2

1. Set `enable_client = true`, apply, reboot CL01 so it takes the DC as DNS
2. Domain join CL01
3. Configure hybrid Entra join through Entra Connect, verify with `dsregcmd /status`

**Exit criteria.** `AzureAdJoined: YES` and `DomainJoined: YES` on CL01, and the
device listed as Microsoft Entra hybrid joined in the portal.

---

## Phase 4. Conditional Access as code: Blocked on Phase 3

The centrepiece. Terraform `azuread` provider, policies under version control.

1. Create a break-glass account and exclude it from every policy. Document why.
   This is the single detail that separates a real deployment from a demo
2. Write policies as `azuread_conditional_access_policy` in
   `enabledForReportingButNotEnforced`:

   | Policy | Intent |
   |---|---|
   | Require MFA, all users, all resources | Baseline |
   | Require hybrid joined or compliant device for admins | Ties Phase 3 to access control |
   | Block legacy authentication | Closes the bypass that makes MFA theatre |
   | Named location for trusted egress | Demonstrates condition scoping |

3. Review impact in the sign-in logs and the What If tool before enforcing
4. Flip to `enabled` one policy at a time, capturing evidence at each step

Report-only first is not caution for its own sake. A block policy scoped to all
resources can lock every administrator out of the tenant, and the break-glass
account is the only way back.

**Exit criteria.** Policies applied from Terraform, report-only evidence captured,
then enforced without locking anyone out.

---

## Phase 5. Governance: Requires P2

1. Dynamic group membership driven by synced on-prem attributes
2. Access reviews over a privileged group
3. PIM: an admin role made eligible rather than permanent, with approval

**Exit criteria.** A documented just-in-time elevation with an audit trail.

---

## Notes

**Cost control.** Auto-shutdown stops the VMs daily and does not restart them,
which is the point. CL01 stays off until Phase 3. Bastion is the free Developer
SKU. `terraform destroy` removes everything.

**Evidence.** Each phase should leave something a reader can check: a screenshot,
`dsregcmd` output, a sign-in log extract. The lab is not the deliverable, the
evidence that it works is.

**Known gaps.** State is local, unlocked and unversioned, and holds the admin
password in plaintext. Acceptable for a single-operator prototype, recorded here
rather than pretended away. An `azurerm` backend is the fix if this ever becomes
shared.
