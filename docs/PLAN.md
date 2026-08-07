# Roadmap

Phases ordered by dependency, each blocked by the one above it. Phases 2 to 4 connect the forest to
Entra ID, phases 5 to 8 manage and harden the endpoints inside it, and Phase 7 is where they meet:
Group Policy delivering a LAPS policy whose secret lands in the cloud.

Full detail, commands and evidence live in the phase documents. This file is status and what each
phase carried forward.

| Phase | Focus | Status | Walkthrough |
|---|---|---|---|
| 0 | Azure infrastructure: network, VMs, Bastion | Completed | [00-infrastructure.md](docs/00-infrastructure.md) |
| 1 | Forest, DNS, domain join, directory | Completed | [01-ad-environment.md](docs/01-ad-environment.md) |
| 2 | Entra Connect Sync, scoped to one OU | Completed | [02-entra-connect.md](docs/02-entra-connect.md) |
| 3 | Branch office network, second region | Completed | [03-branch-network.md](docs/03-branch-network.md) |
| 4 | AD sites, domain join, hybrid Entra join | Completed | [04-hybrid-join.md](docs/04-hybrid-join.md) |
| 5 | Group Policy foundation | Completed | [05-group-policy.md](docs/05-group-policy.md) |
| 6 | Security baselines | Completed | [06-security-baselines.md](docs/06-security-baselines.md) |
| 7 | Windows LAPS, both backends | Completed | [07-windows-laps.md](docs/07-windows-laps.md) |
| 8 | Tiered administration | **Not implemented** | [08-tiered-administration.md](docs/08-tiered-administration.md) |

Each phase document ends in an exit-criteria table with the command that proves it.

> **Everything through Phase 7 is free.** Connect Sync, hybrid Entra join and Windows LAPS all work
> on Entra ID Free. The lab stops before Conditional Access (P1) and PIM (P2). See
> [docs/decisions.md](docs/decisions.md).

---

## Carried forward between phases

| Item | Raised | Closed |
|---|---|---|
| Enable the AD Recycle Bin | Phase 2, by the Connect Sync wizard | Phase 5 |
| Restore IE ESC on CS01 | Phase 2, disabled for the installer | Phase 5 |
| Seamless SSO intranet zone assignment | Phase 2, the feature does nothing without it | Phase 5 |
| ICMP blocked across the peering | Phase 3, observed as a non-fault | Phase 5, by policy |
| Security filtering rehearsal | Phase 5, on `Loopback-Demo` | Phase 6 and 7, used for real |
| `LAPS.admx` in the Central Store | Phase 5 | Phase 7, needed to author the policy |
| Roll the Seamless SSO Kerberos key every 30 days | Phase 2 | **Open**, manual, see the risk register |
| Shared local administrator credential | Phase 0 | **Partly.** CL01 and CL02 covered by Phase 7; CS01 and the domain `labadmin` are Phase 8 |
| Export the GPO estate into the repo | Phase 5 | **Deferred.** Bastion Basic has no file transfer |

## Deviations from the original plan

**Phase 3 did not exist.** The clients would not fit inside the Sweden Central vCPU quota, which a
free trial cannot raise. Moving them to a second region added cross-region peering and gave Phase 4
a real reason for AD Sites and Services.

**Policy Analyzer was dropped for Group Policy Modeling** in Phase 6. It runs on the endpoint rather
than centrally, its comparison step is GUI-only, and on the hardened client the baseline blocked it
from starting. See `decisions.md` entry 16.

**The Phase 5 loopback demonstration was set up but not run.** CL02 is the untouched control Phase 6
measures against, so user configuration on it would weaken the comparison. The GPO is built,
filtered and unlinked.

**Two Phase 7 verifications are not captured:** a successful decryption as `sg-it-admins`, and a
rotation.

## Where the lab stops

Conditional Access is the natural next step after hybrid join: require a hybrid-joined device for
admin access, and the two halves of this lab become one control. It needs Entra ID P1, which is
unobtainable here.

Phase 8 would split the single Domain Admin account into a tiered model and bring CS01 under LAPS.
Not executed or validated; the design is in
[08-tiered-administration.md](docs/08-tiered-administration.md) and the residual risk is in
[docs/risk-and-limitations.md](docs/risk-and-limitations.md).

## Operating notes

**Start DC01 first, every session.** Both networks use it for DNS.

**Cost control.** Auto-shutdown stops the HQ VMs daily and does not restart them. The branch clients
have no schedule and need `az vm deallocate` by hand. Bastion is gated behind `enable_bastion` and
bills hourly. `terraform destroy` removes everything, branch root first.

**Known gaps.** State is local, unlocked and unversioned, and holds the admin password in plaintext.
