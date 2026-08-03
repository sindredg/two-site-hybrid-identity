# Domain join

The join runs **on the machine being joined**, not on CS01. It authenticates as a
domain account the client does not yet know, which is passed to DC01 to authorise
creating the computer object.

Verification runs on CS01, against the directory.

See [Phase 4](../docs/04-hybrid-join.md).

## Pre-flight, on the client

```powershell
ipconfig /all
```

`DNS Servers` must read `10.10.1.4`, not `168.63.129.16`. Azure DNS knows nothing
about `sindredg.local`, and a join attempted against it fails with a message that
reads like bad credentials.

If it is wrong, the NIC has not picked up the VNet setting and the machine needs a
restart.

```powershell
nltest /dsgetdc:sindredg.local
```

This is the real check. It exercises DNS, LDAP and Kerberos in one step, which is
exactly what the join will do. Ping is not a substitute: nothing in a join uses
ICMP, and Windows Server blocks it by default anyway.

```powershell
Test-NetConnection 10.10.1.4 -Port 389
```

## Join, on the client

`-OUPath` places the computer object directly in the synced OU. Without it the
object lands in the default `Computers` container, outside `OU=Sync`, where Entra
Connect will never see it:

```powershell
Add-Computer -DomainName sindredg.local -OUPath "OU=Workstations,OU=Sync,DC=sindredg,DC=local" -Credential (Get-Credential SINDREDG\labadmin) -Restart
```

The Bastion session drops with the restart.

## Confirm, on the client

```powershell
Get-ComputerInfo -Property CsDomain, CsDomainRole
```

| Value | Meaning |
|---|---|
| `StandaloneServer` | Not joined |
| `MemberServer` | Joined. Expected for Server SKUs |
| `MemberWorkstation` | Joined. Expected for Windows client SKUs |
| `PrimaryDomainController` / `BackupDomainController` | A domain controller |

## Verify, on CS01

```powershell
Get-ADComputer -Filter * -SearchBase "OU=Workstations,OU=Sync,DC=sindredg,DC=local" | Select-Object Name, DistinguishedName
```

Every computer in the forest, which catches objects that landed somewhere
unexpected:

```powershell
Get-ADComputer -Filter * -Properties DistinguishedName | Select-Object Name, DistinguishedName
```

## Moving an object that landed in the wrong place

```powershell
Get-ADComputer CL01 | Move-ADObject -TargetPath "OU=Workstations,OU=Sync,DC=sindredg,DC=local"
```

## Leaving the domain

```powershell
Remove-Computer -UnjoinDomainCredential (Get-Credential SINDREDG\labadmin) -Restart
```

The computer object stays in AD and has to be deleted separately:

```powershell
Remove-ADComputer -Identity CL01
```
