# Entra Connect Sync and hybrid join

Sync commands run on CS01. Device state commands run on the client.

See [Phase 2](../docs/02-entra-connect.md) and [Phase 4](../docs/04-hybrid-join.md).

## The module has to be imported first

`ADSync` ships with Entra Connect but sits outside the default PowerShell module
path, so `Import-Module ADSync` by name fails. Use the full path, once per session:

```powershell
Import-Module "C:\Program Files\Microsoft Azure AD Sync\Bin\ADSync\ADSync.psd1"
```

If the install landed elsewhere:

```powershell
Get-ChildItem "C:\Program Files" -Recurse -Filter ADSync.psd1 -ErrorAction SilentlyContinue
```

## Running a sync

```powershell
Start-ADSyncSyncCycle -PolicyType Delta
```

```powershell
Start-ADSyncSyncCycle -PolicyType Initial
```

**The difference matters.** `Delta` only picks up objects that changed since the
last run. An object that was never in scope, or was created before the last full
import, has no change to detect and stays invisible. `Initial` re-reads everything
and is the one to reach for when something is missing rather than stale.

`Sync is already running` is not a failure. The scheduler runs its own delta every
30 minutes and refuses to start a second on top. Wait for it:

```powershell
while ((Get-ADSyncScheduler).SyncCycleInProgress) { Start-Sleep 15; "still running" }; "cycle complete"
```

## Scheduler state

```powershell
Get-ADSyncScheduler | Select-Object SyncCycleEnabled, SyncCycleInProgress, NextSyncCycleStartTimeInUTC
```

## What is in scope

```powershell
(Get-ADSyncConnector | Where-Object { $_.Type -eq "AD" }).Partitions[0].ConnectorPartitionScope.ContainerInclusionList
```

Selecting a parent OU includes its children, so `OU=Sync` covers
`OU=Workstations,OU=Sync` without listing it separately.

## Whether an object reached the sync pipeline

Upstream of Entra, so it tells you where something stalled:

```powershell
$conn = (Get-ADSyncConnector | Where-Object { $_.Type -eq "AD" }).Name
Get-ADSyncCSObject -ConnectorName $conn -DistinguishedName "CN=CL01,OU=Workstations,OU=Sync,DC=sindredg,DC=local"
```

## Hybrid join

The wizard writes a service connection point into the forest. Confirm it rather
than trusting the success page:

```powershell
Get-ADObject -Filter 'ObjectClass -eq "serviceConnectionPoint"' -SearchBase "CN=Device Registration Configuration,CN=Services,CN=Configuration,DC=sindredg,DC=local" -Properties keywords | Select-Object -ExpandProperty keywords
```

Returns `azureADName:` with the tenant domain and `azureADId:` with its GUID.

## Device state, on the client

```powershell
dsregcmd /status
```

| State | Meaning |
|---|---|
| `DomainJoined: YES`, `AzureAdJoined: NO` | Joined on-premises only. Usually the computer object has not reached Entra yet |
| `DomainJoined: YES`, `AzureAdJoined: YES` | Hybrid joined |
| Both `NO` | Not joined to anything |

```powershell
Start-ScheduledTask -TaskPath "\Microsoft\Windows\Workplace Join\" -TaskName "Automatic-Device-Join"
```

Registration runs on that task at boot and is not instant. Trigger it rather than
restarting again.

```powershell
dsregcmd /debug /join
```

Verbose output including the response from `enterpriseregistration.windows.net`.
Use when the status is wrong and the reason is not obvious.

## Checking the tenant instead

From the workstation, which avoids clicking through the portal:

```bash
az rest --method GET --url "https://graph.microsoft.com/v1.0/devices"
```

`operatingSystemVersion` is written by the device during registration, not by the
sync. An object with it empty was created by Connect Sync and never touched by the
machine, which distinguishes a device that is still waiting from one that is
genuinely failing.
