<#
.SYNOPSIS
    Creates the tiered administration OUs, groups and admin accounts, and moves
    member servers out of the Computers container.

.DESCRIPTION
    Run on CS01 with RSAT, as a Domain Admin. Idempotent - every object is checked
    before it is created, so a second run reports "exists" and changes nothing.

    Admin accounts are placed under OU=NoSync deliberately. Entra Connect is scoped
    to OU=Sync, so a privileged on-premises account never gains a cloud object and
    therefore never gains a second attack path onto the same credential. Tier 0 goes
    further: sg-tier0-admins is created under NoSync rather than beside the other
    sg- groups, so Tier 0 has no representation in Entra ID at all.

    This script builds structure only. It grants no rights and denies no logons -
    the deny-logon policy is authored in GPMC, because User Rights Assignment is not
    registry-backed and has no cmdlet.

    labadmin is not modified. Until t0-admin has been proven to work it is the only
    verified way into the forest.

.EXAMPLE
    .\04-tier-structure.ps1 -DomainName sindredg.local

.EXAMPLE
    .\04-tier-structure.ps1 -DomainName sindredg.local -ServersToMove CS01,APP01

.NOTES
    Phase 8, steps 3 to 6. Passwords are prompted rather than defaulted so they
    never sit in the repo, and each account is prompted separately so they do not
    end up sharing one - which would rebuild the exact problem this phase removes.
#>
[CmdletBinding()]
param(
    [string]$DomainName = 'sindredg.local',

    # NetBIOS name, used when qualifying principals.
    [string]$NetBiosName = 'SINDREDG',

    # Member servers to relocate out of CN=Computers into OU=Servers. A container
    # is not an OU and cannot be a Group Policy link target, which is what blocked
    # LAPS on CS01 in Phase 7.
    [string[]]$ServersToMove = @('CS01')
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
        # Matches 02-ad-structure.ps1: protection off, because it blocks teardown
        # and this is a disposable lab.
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $false
        Write-Host "  created OU $Name" -ForegroundColor Green
    }
    return $dn
}

# ---------------------------------------------------------------------------
Write-Host "== Organisational units ==" -ForegroundColor Cyan

# Servers sits at the domain root, not under NoSync: NoSync holds accounts and
# this holds computers. A GPO linked here should not inherit policy written for
# service accounts.
$serversDN = New-OuIfMissing -Name 'Servers' -Path $domainDN

$noSyncDN = "OU=NoSync,$domainDN"
$adminDN  = New-OuIfMissing -Name 'Admin' -Path $noSyncDN

$tierDN = @{}
foreach ($t in 'Tier0', 'Tier1', 'Tier2') {
    $tierDN[$t] = New-OuIfMissing -Name $t -Path $adminDN
}

# ---------------------------------------------------------------------------
Write-Host "`n== Groups ==" -ForegroundColor Cyan

# Only Tier 0 needs a new group. sg-it-admins and sg-helpdesk were created in
# Phase 1 already carrying Tier 1 and Tier 2 descriptions; this phase is what
# makes those descriptions true.
if (Get-ADGroup -Filter "Name -eq 'sg-tier0-admins'" -ErrorAction SilentlyContinue) {
    Write-Host "  exists  sg-tier0-admins"
} else {
    New-ADGroup -Name 'sg-tier0-admins' -GroupScope Global -GroupCategory Security `
        -Path $adminDN `
        -Description 'Tier 0 administrators - domain controllers only. Outside sync scope by design.'
    Write-Host "  created sg-tier0-admins (outside sync scope)" -ForegroundColor Green
}

foreach ($g in 'sg-it-admins', 'sg-helpdesk') {
    if (-not (Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue)) {
        throw "$g not found. Run 02-ad-structure.ps1 first - Phase 8 reuses the Phase 1 groups."
    }
}

# ---------------------------------------------------------------------------
Write-Host "`n== Tier admin accounts ==" -ForegroundColor Cyan

$admins = @(
    @{ Sam = 't0-admin'; Tier = 'Tier0'; Group = 'sg-tier0-admins'; Desc = 'Tier 0. Domain controllers only.' }
    @{ Sam = 't1-admin'; Tier = 'Tier1'; Group = 'sg-it-admins';    Desc = 'Tier 1. Member servers only.' }
    @{ Sam = 't2-admin'; Tier = 'Tier2'; Group = 'sg-helpdesk';     Desc = 'Tier 2. Workstations only.' }
)

foreach ($a in $admins) {
    if (Get-ADUser -Filter "SamAccountName -eq '$($a.Sam)'" -ErrorAction SilentlyContinue) {
        Write-Host "  exists  $($a.Sam)"
    } else {
        # Prompted per account. Three accounts sharing one password would rebuild
        # the flat-credential problem this phase exists to remove.
        $pw = Read-Host -AsSecureString "  Password for $($a.Sam)"

        # -Enabled is an argument to New-ADUser only. Omitting it creates an
        # account that exists, lists correctly, and refuses every logon - the trap
        # the seed users hit in Phase 1.
        New-ADUser -Name $a.Sam -SamAccountName $a.Sam `
            -UserPrincipalName "$($a.Sam)@$DomainName" `
            -Path $tierDN[$a.Tier] `
            -AccountPassword $pw -Enabled $true `
            -Description $a.Desc
        Write-Host "  created $($a.Sam) in $($a.Tier)" -ForegroundColor Green
    }

    # Membership is checked separately so re-runs repair drift rather than error.
    $member = Get-ADGroupMember -Identity $a.Group -ErrorAction SilentlyContinue |
              Where-Object { $_.SamAccountName -eq $a.Sam }
    if (-not $member) {
        Add-ADGroupMember -Identity $a.Group -Members $a.Sam
        Write-Host "          added to $($a.Group)" -ForegroundColor Green
    }
}

# t0-admin needs forest privilege before labadmin can be retired. labadmin stays
# in Domain Admins: it is RID 500, cannot be deleted, and is the break-glass
# account that still works when everything else is broken.
$da = Get-ADGroupMember -Identity 'Domain Admins' | Where-Object { $_.SamAccountName -eq 't0-admin' }
if (-not $da) {
    Add-ADGroupMember -Identity 'Domain Admins' -Members 't0-admin'
    Write-Host "          t0-admin added to Domain Admins" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
Write-Host "`n== Member server relocation ==" -ForegroundColor Cyan

foreach ($s in $ServersToMove) {
    $computer = Get-ADComputer -Filter "Name -eq '$s'" -ErrorAction SilentlyContinue
    if (-not $computer) {
        Write-Warning "  $s not found in the directory, skipped"
        continue
    }

    if ($computer.DistinguishedName -like "*$serversDN") {
        Write-Host "  in place $s"
    } else {
        # The SID and computer password are unchanged by a move, so domain
        # membership and any service running on the machine are unaffected.
        Move-ADObject -Identity $computer.DistinguishedName -TargetPath $serversDN
        Write-Host "  moved   $s from $($computer.DistinguishedName -replace '^CN=[^,]+,', '')" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
Write-Host "`n== Summary ==" -ForegroundColor Cyan

'sg-tier0-admins', 'sg-it-admins', 'sg-helpdesk', 'Domain Admins' | ForEach-Object {
    [PSCustomObject]@{
        Group   = $_
        Members = ((Get-ADGroupMember $_).SamAccountName | Sort-Object) -join ', '
    }
} | Format-Table -AutoSize

Write-Host "Structure only. No logon rights have been granted or denied." -ForegroundColor Yellow
Write-Host "Next: author the deny-logon GPOs in GPMC. See docs/08-tiered-administration.md" -ForegroundColor Cyan
