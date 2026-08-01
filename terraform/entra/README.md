# Entra ID Terraform root

Phase 4. Not yet built. Blocked on an Entra ID P1 licence, which the tenant does
not currently hold.

This is a **separate root** from `terraform/azure/` on purpose, with its own
state. A bad Conditional Access apply can lock every administrator out of the
tenant, and that plan must never be entangled with one that can also rebuild a
domain controller. Reasoning in full in `../../docs/decisions.md`.

## What goes here

| Resource | Purpose |
|---|---|
| `azuread_conditional_access_policy` | The policies themselves, shipped in `enabledForReportingButNotEnforced` first |
| `azuread_named_location` | Trusted egress, to demonstrate condition scoping |
| `azuread_group` | Cloud-only groups for policy targeting |
| `azuread_user` | The break-glass account, excluded from every policy |

## Before the first apply

The break-glass account must exist and be excluded from every policy **before**
any policy is enabled. It is the only way back from a lockout. Create it first,
verify it can sign in, and document the exclusion.

Report-only is not caution for its own sake. A block policy scoped to all
resources will lock out the tenant, and there is no undo from outside it.

## Provider

`hashicorp/azuread`, pinned when this root is created. Authentication is to
Microsoft Graph, not ARM, so `az login` scopes differ from the Azure root.

Note the API rate limit of roughly one request per second on Conditional Access
policies. Applies here are slower than they look like they should be.
