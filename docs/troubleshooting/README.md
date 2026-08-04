# Troubleshooting log

Problems hit during the build, their causes, and the fixes. Error strings are
verbatim so they are searchable.

The phase walkthroughs describe the path that worked. Everything that went wrong
lives here instead, so the two can be read for different purposes: one to follow,
one to search when something breaks.

| Phase | File | Theme |
|---|---|---|
| 0 | [00-infrastructure.md](00-infrastructure.md) | Terraform ordering races, and a region with no v1 B-series |
| 1 | [01-ad-environment.md](01-ad-environment.md) | Three bugs in our own scripts, two sharing a root cause: trusting state read before a change instead of re-reading after it |
| 2 | [02-entra-connect.md](02-entra-connect.md) | A Windows Server default, a correct refusal, and one thing still unexplained |
| 3 | [03-branch-network.md](03-branch-network.md) | Three regions, three different reasons a region can be unusable |
| 4 | [04-hybrid-join.md](04-hybrid-join.md) | A missing module path, and a sync that reported success while syncing nothing new |
| 5 | [05-group-policy.md](05-group-policy.md) | Four machines and two accounts sharing a name, and a file copy that reported success while copying half |

## Recurring themes

Worth reading across phases rather than within them.

**A guard that fails closed looks identical to success.** The preflight that
wrongly reported "already a domain controller" and the `-EnableUsers` switch that
silently did nothing both produced confident, wrong output rather than an error.

**A partial check of a multi-part operation passes while the operation is broken.**
The Phase 1 guard that tested only whether an object existed, and the Phase 5
template count that proved 214 files had copied while every language file was
missing, are the same mistake at two different layers.

**Scripts that both change and verify must re-read in between.** Two separate
Phase 1 bugs came from filtering a collection fetched before the change.

**The error names the symptom, not the cause.** The Group Policy Client hang named
`gpsvc` when the cause was `SysvolReady = 0`. The Entra sign-in blamed JavaScript
when the cause was Internet Explorer Enhanced Security Configuration.

**Terraform orders what it can see.** Three separate Phase 0 failures came from two
operations with no dependency edge between them running concurrently.
