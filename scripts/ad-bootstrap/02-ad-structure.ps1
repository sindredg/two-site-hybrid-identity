<#
.SYNOPSIS
    Creates the OU structure, security groups and seed users to synchronise.

.DESCRIPTION
    Run on DC01 after promotion. Idempotent - every object is checked before it is
    created, so a second run reports "exists" and changes nothing.

    The structure deliberately separates synced objects from non-synced ones, so
    Entra Connect can be scoped by OU in Phase 2 and you can demonstrate filtering
    rather than syncing the whole directory.

.EXAMPLE
    .\02-ad-structure.ps1 -DomainName lab.local

.NOTES
    Phase 1, step 4. Users are created disabled by default - enable them once you
    have confirmed the sync scope is right.
#>
[CmdletBinding()]
param(
    [string]$DomainName = 'lab.local',

    # Seed users are created with this password, then required to change it.
    # Prompted rather than defaulted so it never sits in the repo.
    [Parameter(Mandatory)]
    [securestring]$InitialPassword,

    [switch]$EnableUsers
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$domainDN = (Get-ADDomain -Identity $DomainName).DistinguishedName
Write-Host "Domain: $DomainName ($domainDN)`n" -ForegroundColor Cyan

function New-OuIfMissing {
    param([string]$Name, [string]$Path)

    $dn = "OU=$Name,$Path"
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue) {
        Write-Host "  exists  OU $Name"
    } else {
        # ProtectedFromAccidentalDeletion defaults to true, which blocks the
        # teardown script later. Off deliberately - this is a disposable lab.
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $false
        Write-Host "  created OU $Name" -ForegroundColor Green
    }
    return $dn
}

Write-Host "== Organisational units ==" -ForegroundColor Cyan

# Everything under Sync is what Entra Connect will be scoped to. Everything
# outside it stays on-prem only - that contrast is the point.
$syncDN     = New-OuIfMissing -Name 'Sync'        -Path $domainDN
$usersDN    = New-OuIfMissing -Name 'Users'       -Path $syncDN
$groupsDN   = New-OuIfMissing -Name 'Groups'      -Path $syncDN
$computerDN = New-OuIfMissing -Name 'Workstations' -Path $syncDN
$noSyncDN   = New-OuIfMissing -Name 'NoSync'      -Path $domainDN
$svcDN      = New-OuIfMissing -Name 'ServiceAccounts' -Path $noSyncDN

Write-Host "`n== Security groups ==" -ForegroundColor Cyan

$groups = @(
    @{ Name = 'sg-finance';     Description = 'Finance department - Conditional Access target' }
    @{ Name = 'sg-it-admins';   Description = 'IT administrators - require hybrid joined device' }
    @{ Name = 'sg-helpdesk';    Description = 'Helpdesk - access review target in Phase 5' }
    @{ Name = 'sg-contractors'; Description = 'External contractors - stricter CA policy' }
)

foreach ($g in $groups) {
    if (Get-ADGroup -Filter "Name -eq '$($g.Name)'" -ErrorAction SilentlyContinue) {
        Write-Host "  exists  $($g.Name)"
    } else {
        New-ADGroup -Name $g.Name -GroupScope Global -GroupCategory Security `
                    -Path $groupsDN -Description $g.Description
        Write-Host "  created $($g.Name)" -ForegroundColor Green
    }
}

Write-Host "`n== Seed users ==" -ForegroundColor Cyan

# Realistic attributes matter here: Entra Connect syncs these, and Conditional
# Access can target on department or job title later.
$users = @(
    @{ First = 'Astrid'; Last = 'Lindqvist'; Dept = 'Finance';    Title = 'Financial Controller'; Group = 'sg-finance' }
    @{ First = 'Bjorn';  Last = 'Karlsson';  Dept = 'Finance';    Title = 'Analyst';              Group = 'sg-finance' }
    @{ First = 'Celine'; Last = 'Dubois';    Dept = 'IT';         Title = 'Systems Engineer';     Group = 'sg-it-admins' }
    @{ First = 'Dmitri'; Last = 'Volkov';    Dept = 'IT';         Title = 'Service Desk Analyst'; Group = 'sg-helpdesk' }
    @{ First = 'Elena';  Last = 'Rossi';     Dept = 'External';   Title = 'Contractor';           Group = 'sg-contractors' }
)

foreach ($u in $users) {
    $sam = ($u.First.Substring(0,1) + $u.Last).ToLower()
    $upn = "$sam@$DomainName"

    if (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
        Write-Host "  exists  $sam"
    } else {
        New-ADUser `
            -Name              "$($u.First) $($u.Last)" `
            -GivenName         $u.First `
            -Surname           $u.Last `
            -SamAccountName    $sam `
            -UserPrincipalName $upn `
            -DisplayName       "$($u.First) $($u.Last)" `
            -Department        $u.Dept `
            -Title             $u.Title `
            -Path              $usersDN `
            -AccountPassword   $InitialPassword `
            -ChangePasswordAtLogon $true `
            -Enabled           $EnableUsers.IsPresent
        Write-Host "  created $sam ($($u.Dept))" -ForegroundColor Green
    }

    # Membership is checked separately so re-runs repair drift rather than error.
    $member = Get-ADGroupMember -Identity $u.Group -ErrorAction SilentlyContinue |
              Where-Object { $_.SamAccountName -eq $sam }
    if (-not $member) {
        Add-ADGroupMember -Identity $u.Group -Members $sam
        Write-Host "          added to $($u.Group)" -ForegroundColor Green
    }
}

Write-Host "`n== Summary ==" -ForegroundColor Cyan
Write-Host "Users in sync scope: $((Get-ADUser -Filter * -SearchBase $usersDN).Count)"
Write-Host "Groups:              $((Get-ADGroup -Filter * -SearchBase $groupsDN).Count)"
if (-not $EnableUsers) {
    Write-Host "`nUsers are DISABLED. Re-run with -EnableUsers once the sync scope is confirmed." -ForegroundColor Yellow
}
Write-Host "`nNext: .\03-prep-sync.ps1" -ForegroundColor Cyan
