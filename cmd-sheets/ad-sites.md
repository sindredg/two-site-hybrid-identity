# AD Sites and Services

Run from CS01, which has RSAT. These write to the directory rather than to any one
machine, so Server Core never needs a session.

Relevant once the lab spans more than one network. See
[Phase 4](../docs/04-hybrid-join.md).

## Current state

```powershell
Get-ADReplicationSite -Filter * | Select-Object Name
```

```powershell
Get-ADReplicationSubnet -Filter * | Select-Object Name, Site
```

A fresh forest has one site, `Default-First-Site-Name`, and no subnets.

## Naming the sites

Renaming the default site is less work than creating a new one and moving the
domain controller into it:

```powershell
Rename-ADObject -Identity (Get-ADReplicationSite -Identity "Default-First-Site-Name").DistinguishedName -NewName "HQ-SwedenCentral"
```

```powershell
New-ADReplicationSite -Name "Branch-DenmarkEast"
```

## Mapping subnets to sites

This is the part that does the work. A client picks its site by matching its own
address against these:

```powershell
New-ADReplicationSubnet -Name "10.10.1.0/24" -Site "HQ-SwedenCentral"
```

```powershell
New-ADReplicationSubnet -Name "10.20.1.0/24" -Site "Branch-DenmarkEast"
```

## Which site a machine thinks it is in

From any domain-joined machine:

```powershell
nltest /dsgetdc:sindredg.local
```

`Our Site Name` is the client, `Dc Site Name` is the domain controller it found.
Two different values means the mapping is working.

```powershell
Get-ADDomainController -Discover
```

## Moving a domain controller between sites

Not needed in this lab, but the counterpart to renaming:

```powershell
Move-ADDirectoryServer -Identity DC01 -Site "HQ-SwedenCentral"
```

## Removing a mapping

```powershell
Remove-ADReplicationSubnet -Identity "10.20.1.0/24"
```
