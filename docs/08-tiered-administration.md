# Phase 8. Tiered administration (planned)

> **Status: Not implemented.** This optional hardening phase has not been executed
> or validated. The current milestone ends after Phase 7, but this phase may be
> implemented later. Everything below is a plan, not a claim about the deployed
> environment.

## Current stopping point

Phases 0 to 7 deliver the intended outcome: repeatable Azure infrastructure, a
two-site AD forest, Entra synchronization and hybrid join, Group Policy, measured
security baselines, and Windows LAPS using both storage backends. The remaining flat
domain-administrator model is a documented lab limitation, not production-ready
security.

**Goal:** stop using one Domain Admin account for everything, the second weakness
named in [risk-and-limitations.md](risk-and-limitations.md). Phase 7 removed the
shared *local* administrator password; this removes the shared *domain* one.

---

## 1. The problem being fixed

`labadmin` is currently the local administrator on every machine, the Domain Admin,
and the account used for routine work. Any credential theft anywhere in the lab is
immediately a forest compromise. That is the exact condition tiering exists to
prevent.

---

## 2. Tier model

| Tier | Contains | Admin account | May sign into |
|---|---|---|---|
| 0 | DC01 | `t0-admin` | Domain controllers only |
| 1 | CS01 | `t1-admin` | Member servers |
| 2 | CL01, CL02 | `t2-admin` | Workstations |

The rule is one-directional: a higher-tier credential must never be typed into a
lower-tier machine, because a compromised lower tier can capture it.

`sg-it-admins` and `sg-helpdesk` from Phase 1 map onto Tiers 1 and 2. Their
descriptions were updated for this when the lab was rescoped.

---

## 3. Enforcement

Group Policy User Rights Assignment, linked per tier:

| Right | Applied to | Denies |
|---|---|---|
| Deny log on locally | DC01 | Tier 1 and Tier 2 accounts |
| Deny log on through Remote Desktop Services | DC01 | Tier 1 and Tier 2 accounts |
| Deny log on locally | Workstations | Tier 0 accounts |
| Deny access from the network | Workstations | Tier 0 accounts |

Restricted Groups, or Group Policy Preferences, then control who is in the local
Administrators group on the clients, so local admin rights are policy rather than
whatever was configured at build time.

---

## 4. Verification

The evidence for this phase is a **failure**, not a success. Attempt a cross-tier
logon and have it refused:

1. Sign into CL01 as `t2-admin`. Expected to work
2. Attempt a Bastion RDP session to DC01 as `t2-admin`. Expected to be refused
3. Capture the denial in the Security event log on DC01

An access attempt that fails, with the log entry showing why, proves the boundary
exists. A screenshot of a successful logon proves nothing about what is blocked.

---

## 5. Exit criteria

| Criterion | Status |
|---|---|
| Tier OU structure and per-tier admin accounts created | Pending |
| Deny-logon rights applied by GPO per tier | Pending |
| Local Administrators membership controlled by policy | Pending |
| Cross-tier logon attempted and refused | Pending |
| Denial captured in the event log | Pending |
| Shared Domain Admin entry in the risk register closed | Pending |

---

## Where the lab ends

After this phase, the natural continuation would be
Conditional Access requiring a hybrid-joined device for administrative access.
That requires Entra ID P1, which was unavailable to this tenant. The current
milestone stops at the tested Phase 7 boundary rather than presenting an unverified
control.
