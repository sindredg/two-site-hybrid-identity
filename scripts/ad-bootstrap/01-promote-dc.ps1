<#
.SYNOPSIS
    Promotes DC01 to a new Active Directory forest and installs DNS.

.DESCRIPTION
    Run on DC01 only, over an Azure Bastion session. DC01 is Server Core, so you
    get a command prompt rather than a desktop - type powershell to get a shell.

    The machine reboots on success. That is expected.

    Safe to re-run: if the forest already exists the script reports it and exits
    without changing anything.

.EXAMPLE
    .\01-promote-dc.ps1 -DomainName lab.local

.NOTES
    Phase 1, step 1. After the reboot, set dns_servers = ["10.10.1.4"] in
    terraform.tfvars, re-apply, and reboot CS01 before joining it to the domain.
#>
[CmdletBinding()]
param(
    # Use a domain you control if you can. See the note at the foot of this file.
    [string]$DomainName = 'lab.local',

    [string]$NetbiosName = 'LAB'
)

$ErrorActionPreference = 'Stop'

Write-Host "== Preflight ==" -ForegroundColor Cyan

# Promoting a DC that is already a DC is not merely wasteful, it fails in
# confusing ways. Check first.
if (Get-Service -Name NTDS -ErrorAction SilentlyContinue) {
    Write-Host "NTDS service present - this machine is already a domain controller." -ForegroundColor Yellow
    Get-ADDomain | Select-Object DNSRoot, NetBIOSName, DomainMode | Format-List
    Write-Host "Nothing to do." -ForegroundColor Green
    return
}

# A DC must have a static address. Ours is pinned in Terraform to 10.10.1.4, but
# verify rather than assume - a DC on a changing IP breaks DNS for the whole lab.
$ip = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway }).IPv4Address.IPAddress
Write-Host "Primary IPv4 address: $ip"
if ($ip -ne '10.10.1.4') {
    Write-Warning "Expected 10.10.1.4 (the address pinned in vms.tf). Found $ip."
    Write-Warning "Continuing, but the VNet DNS setting in terraform.tfvars must match this address."
}

Write-Host "`n== Installing AD DS role ==" -ForegroundColor Cyan
$feature = Get-WindowsFeature -Name AD-Domain-Services
if ($feature.Installed) {
    Write-Host "AD-Domain-Services already installed."
} else {
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
    Write-Host "Installed." -ForegroundColor Green
}

Write-Host "`n== Creating forest $DomainName ==" -ForegroundColor Cyan
Write-Host "You will be prompted for a Directory Services Restore Mode password."
Write-Host "Store it somewhere durable - it is not recoverable and not the same as the admin password."
Write-Host "The machine reboots automatically when this completes.`n" -ForegroundColor Yellow

Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $NetbiosName `
    -InstallDns `
    -DomainMode WinThreshold `
    -ForestMode WinThreshold `
    -NoRebootOnCompletion:$false `
    -Force

<#
A note on the domain name.

lab.local is fine for a throwaway forest, but .local is not routable and cannot be
verified in Entra. Users synced from it land on the tenant's onmicrosoft.com suffix
unless you add a routable UPN suffix in AD - which is exactly what 03-prep-sync.ps1
does.

If you own a domain, use a subdomain of it here (corp.example.com) and the whole
UPN story gets simpler.
#>
