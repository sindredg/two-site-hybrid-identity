# Decisions

Choices made during the build, with the reasoning and what was given up. Recorded
so the alternatives are visible rather than implied.

---

## 1. Tooling is split by layer, not unified

No single tool covers all three layers well.

| Layer | Tool | Reasoning |
|---|---|---|
| Azure infrastructure | Terraform `azurerm` | Declarative, diffable, destroys cleanly |
| On-prem AD: forest, OUs, users, groups | PowerShell | Terraform cannot promote a forest at all |
| Entra ID objects and Conditional Access | Terraform `azuread` | Report-only policy state is supported, so policies ship without risking lockout |
| Entra Connect Sync install | Wizard, documented | Not meaningfully codeable |

**Rejected: `hashicorp/ad` for the directory layer.** Version 0.5.0, last
published March 2024, effectively dormant. It also needs WinRM reachability to
the domain controller, which the Bastion-only network design deliberately
removes. Choosing it purely to claim "all IaC" would mean fighting a stale
provider to do something it was never designed for.

**Given up.** The directory layer has no plan and no drift detection. Mitigated by
making the scripts idempotent, so re-running is the drift check.

---

## 2. Two Terraform roots, not one

`terraform/azure/` and `terraform/entra/` have separate state.

| Reason | Detail |
|---|---|
| Blast radius | A bad Conditional Access apply can lock every admin out of the tenant. That plan must never be entangled with "also rebuild a domain controller" |
| Credentials | `azurerm` authenticates to ARM, `azuread` to Graph. Different permissions |
| Change cadence | Infrastructure is stable once built. CA policies get iterated constantly |
| Rollback | Separate state means reverting a policy cannot touch the VMs |

**Given up.** Outputs cannot be referenced directly across roots. Any value both
need has to be passed as a variable or looked up with a data source.

---

## 3. Azure Bastion instead of public IPs

Originally each VM had a Standard static public IP with an NSG rule allowing RDP
from a single home address.

**Changed because** the home IP rotates, which silently breaks access, and more
importantly a domain controller with an internet-facing RDP port is the wrong
thing to publish in a portfolio. The immediate trigger was that `mstsc.exe` does
not exist on recent Windows 11 Home ARM64 builds, so RDP was not usable anyway.

**Developer SKU over Basic.** Free against $0.19/hour, roughly $139/month billed
24/7 with no auto-shutdown, which is around ten times the VM bill. Verified
against the Azure Retail Prices API.

**Given up.** Developer SKU is shared infrastructure and allows one VM connection
at a time, with no native client and no file transfer. Acceptable: once CS01 is
domain-joined, RSAT from CS01 is the better way to administer a Server Core DC
anyway.

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

That split is not a workaround to hide. It is precisely the state a real
`.local`-era environment is in before its first sync, so the lab demonstrates the
same remediation a migration would need.

---

## Pending decisions

| Decision | Phase | Notes |
|---|---|---|
| Password Hash Sync over Pass-through Authentication | 2 | PHS is simpler and survives an on-prem outage. Record the reasoning when chosen |
| Sync filtering scope | 2 | The `Sync` and `NoSync` OU split exists so scoping is demonstrable. Syncing everything would work and prove nothing |
