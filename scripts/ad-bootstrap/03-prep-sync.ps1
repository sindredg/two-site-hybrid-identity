<#
.SYNOPSIS
    Adds a routable UPN suffix and pre-flights the directory for Entra Connect.

.DESCRIPTION
    Run on DC01 after 02-ad-structure.ps1, before installing Entra Connect Sync.

    Catches the problems that otherwise surface as opaque sync errors hours later:
    non-routable UPNs, duplicate proxyAddresses, missing surnames, and users whose
    UPN suffix will not match a verified Entra domain.

    Read-only unless -Apply is passed.

.EXAMPLE
    .\03-prep-sync.ps1 -UpnSuffix contoso.onmicrosoft.com
    .\03-prep-sync.ps1 -UpnSuffix contoso.onmicrosoft.com -Apply

.NOTES
    Phase 1, step 5. UpnSuffix must be a domain already VERIFIED in your Entra
    tenant, otherwise synced users silently fall back to onmicrosoft.com.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$UpnSuffix,

    [string]$DomainName = 'sindredg.local',

    # Without this the script only reports. Nothing is changed.
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$forest   = Get-ADForest
$domainDN = (Get-ADDomain -Identity $DomainName).DistinguishedName
$syncBase = "OU=Users,OU=Sync,$domainDN"

Write-Host "Forest:     $($forest.Name)" -ForegroundColor Cyan
Write-Host "UPN suffix: $UpnSuffix"
Write-Host "Sync scope: $syncBase"
if (-not $Apply) { Write-Host "MODE:       report only (pass -Apply to change anything)`n" -ForegroundColor Yellow }
else             { Write-Host "MODE:       APPLY`n" -ForegroundColor Green }

Write-Host "== UPN suffix ==" -ForegroundColor Cyan

if ($forest.UPNSuffixes -contains $UpnSuffix) {
    Write-Host "  exists  $UpnSuffix is already an alternative UPN suffix"
} elseif ($Apply) {
    Set-ADForest -Identity $forest.Name -UPNSuffixes @{Add = $UpnSuffix}
    Write-Host "  added   $UpnSuffix" -ForegroundColor Green
} else {
    Write-Host "  MISSING $UpnSuffix would be added" -ForegroundColor Yellow
}

Write-Host "`n== Retargeting user UPNs ==" -ForegroundColor Cyan

# .local is not routable and cannot be verified in Entra. Users keeping a .local
# UPN sync as user@tenant.onmicrosoft.com, which breaks the illusion of a real
# hybrid identity and makes sign-in testing confusing.
$users = Get-ADUser -Filter * -SearchBase $syncBase -Properties UserPrincipalName, Surname, GivenName, proxyAddresses

foreach ($u in $users) {
    $current = $u.UserPrincipalName
    $desired = "$($u.SamAccountName)@$UpnSuffix"

    if ($current -eq $desired) {
        Write-Host "  ok      $current"
    } elseif ($Apply) {
        Set-ADUser -Identity $u -UserPrincipalName $desired
        Write-Host "  changed $current -> $desired" -ForegroundColor Green
    } else {
        Write-Host "  WOULD   $current -> $desired" -ForegroundColor Yellow
    }
}

Write-Host "`n== Sync blockers ==" -ForegroundColor Cyan
$problems = 0

# Entra Connect rejects users with no surname or given name on some sync rules.
foreach ($u in $users) {
    if (-not $u.Surname -or -not $u.GivenName) {
        Write-Host "  MISSING NAME  $($u.SamAccountName) - givenName or sn is empty" -ForegroundColor Red
        $problems++
    }
}

# Duplicate proxyAddresses is the single most common cause of a user failing to
# sync. Entra treats the address as a unique key across the tenant.
$allProxies = $users | ForEach-Object { $_.proxyAddresses } | Where-Object { $_ }
$dupes = $allProxies | Group-Object | Where-Object { $_.Count -gt 1 }
foreach ($d in $dupes) {
    Write-Host "  DUPLICATE     proxyAddress $($d.Name) appears $($d.Count) times" -ForegroundColor Red
    $problems++
}

# A UPN suffix that is not verified in Entra silently falls back.
$badSuffix = $users | Where-Object { $_.UserPrincipalName -notlike "*@$UpnSuffix" }
if ($badSuffix -and $Apply) {
    foreach ($u in $badSuffix) {
        Write-Host "  BAD SUFFIX    $($u.SamAccountName) still on $($u.UserPrincipalName)" -ForegroundColor Red
        $problems++
    }
}

Write-Host "`n== Result ==" -ForegroundColor Cyan
if ($problems -eq 0) {
    Write-Host "No blockers found. Directory is ready for Entra Connect Sync." -ForegroundColor Green
} else {
    Write-Host "$problems issue(s) to resolve before installing Entra Connect." -ForegroundColor Red
}

Write-Host @"

Next steps (Phase 2 - needs the P2 trial active):
  1. Verify $UpnSuffix as a custom domain in Entra, if it is not onmicrosoft.com
  2. Install Entra Connect Sync on CS01
  3. Choose Password Hash Sync, and scope filtering to OU=Sync
  4. Force a delta sync:  Start-ADSyncSyncCycle -PolicyType Delta
  5. Confirm the users appear in Entra with onPremisesSyncEnabled = true
"@ -ForegroundColor Cyan
