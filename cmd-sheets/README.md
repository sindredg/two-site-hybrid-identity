# Commands

Every command the lab actually uses, grouped by tool and task, so a phase document
can stay a narrative and this can stay copy-pasteable.

| File | Covers | Runs from |
|---|---|---|
| [terraform.md](terraform.md) | Both roots, plan and apply, state inspection | Workstation, in WSL |
| [azure-cli.md](azure-cli.md) | VM power, quota and size checks, peering, Bastion | Workstation, in WSL |
| [ad-setup.md](ad-setup.md) | Forest promotion, OUs, users, groups | DC01 and CS01 |
| [ad-sites.md](ad-sites.md) | Sites, subnets, replication topology | CS01 |
| [ad-join.md](ad-join.md) | Domain join and computer objects | The joining client, and CS01 |
| [entra-sync.md](entra-sync.md) | Connect Sync cycles, scheduler, hybrid join, device state | CS01 and the clients |
| [laps.md](laps.md) | Windows LAPS schema, permissions, policy, retrieval, diagnostics | CS01 and the clients |
| [group-policy.md](group-policy.md) | Central Store, GPOs, links, filtering, RSoP, backup | CS01 and the clients |

## Conventions

Values that appear throughout:

| Placeholder | This lab |
|---|---|
| Domain | `sindredg.local`, NetBIOS `SINDREDG` |
| HQ resource group | `rg-hybridid-swedencentral` |
| Branch resource group | `rg-branch-office` |
| Admin account | `SINDREDG\labadmin` |
| Synced OU | `OU=Workstations,OU=Sync,DC=sindredg,DC=local` |

The tenant domain is written as `<tenant>.onmicrosoft.com` throughout. Substitute
your own.

**Start DC01 before anything else, every session.** Both networks use it for DNS,
so a deallocated DC01 leaves every other machine unable to resolve anything at all.
