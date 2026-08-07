# Phase 1. Active Directory environment

**Built:** DC01 promoted to a new forest, the virtual network pointed at it, CS01
joined, and a directory structure the later phases target for scoped
synchronisation and Group Policy.

> Scripts in `scripts/ad-bootstrap/`, run over Bastion. See
> [Install a new Active Directory forest](https://learn.microsoft.com/windows-server/identity/ad-ds/deploy/install-a-new-windows-server-2012-active-directory-forest--level-200-).

**Two weaknesses against production.** `sindredg.local` is not routable and cannot
be verified in Entra, so the forest domain and the UPN suffix differ and users need
retargeting before sync ([decisions.md](decisions.md)). And a single local
administrator credential is reused across all VMs and becomes Domain Admin after
promotion ([risk-and-limitations.md](risk-and-limitations.md)).

Problems hit along the way, including two bugs in our own scripts, are in
[troubleshooting/01-ad-environment.md](troubleshooting/01-ad-environment.md).

---

## 1. What gets created

| Object | Name | Purpose |
|---|---|---|
| Forest | `sindredg.local` (NetBIOS `SINDREDG`) | The domain, with DNS on DC01 |
| OU | `OU=Sync` | Everything Entra Connect is scoped to, and the branch Group Policy targets |
| OU | `OU=Users,OU=Sync` | Synced user accounts |
| OU | `OU=Groups,OU=Sync` | Synced security groups |
| OU | `OU=Workstations,OU=Sync` | Where the clients land, and what computer policy and LAPS target |
| OU | `OU=NoSync` | Deliberately outside the sync scope |
| OU | `OU=ServiceAccounts,OU=NoSync` | Proves exclusion works by being absent from Entra |

| Group | Intended use |
|---|---|
| `sg-finance` | Group Policy security filtering target |
| `sg-it-admins` | Tier 1 administrators in the tiered admin model |
| `sg-helpdesk` | Tier 2, and the group denied logon to domain controllers |
| `sg-contractors` | Stricter policy target |

| User | Department | Title | Group |
|---|---|---|---|
| `alindqvist` | Finance | Financial Controller | `sg-finance` |
| `bkarlsson` | Finance | Analyst | `sg-finance` |
| `cdubois` | IT | Systems Engineer | `sg-it-admins` |
| `dvolkov` | IT | Service Desk Analyst | `sg-helpdesk` |
| `erossi` | External | Contractor | `sg-contractors` |

Departments and titles are populated so Group Policy has something realistic to
filter on.

---

## 2. Promoting DC01

DC01 runs Server Core, so a Bastion session lands on a command prompt rather than
a desktop.

The script checks the primary IPv4 address matches the `10.10.1.4` pinned in
Terraform, then installs the AD DS role.

```powershell
.\01-promote-dc.ps1
```

![Preflight and role install](images/phase1/promote-preflight.png)

Promotion itself prompts for a **Directory Services Restore Mode** password. It is
a separate credential from the administrator password, used only for offline
directory recovery, it must satisfy the domain password policy, and it is not
recoverable. It goes in the password manager immediately.

```powershell
Install-ADDSForest -DomainName sindredg.local -DomainNetbiosName SINDREDG -InstallDns -DomainMode WinThreshold -ForestMode WinThreshold -Force
```

**`-InstallDns`.** A domain controller has to answer the SRV record lookups clients
use to find it. A machine that only knows the name `sindredg.local` cannot discover
DC01's address unless something authoritative for that zone answers, which is why
section 3 points the whole virtual network at 10.10.1.4.

![AD DS installed, restarting](images/phase1/addsforest-restart.png)

The machine reboots itself and the Bastion session drops with it.

Three warnings appear during promotion and all three are benign:

| Warning | Why it is safe to ignore |
|---|---|
| NT 4.0 cryptography | Informational. Server 2022 refuses weak algorithms by default, which is what we want |
| DNS delegation cannot be created | Expected for a `.local` root. There is no authoritative parent zone to delegate from |
| No static IP assigned to the adapter | **Must** be ignored on an Azure VM. The address is static in the Azure fabric; the guest has to stay on DHCP to receive it. Hard-coding it inside Windows is a well-known way to lose connectivity entirely |

The forest, confirmed after the reboot:

```powershell
Get-ADDomain | Select-Object DNSRoot, NetBIOSName, DomainMode
```

![Forest created](images/phase1/get-addomain.png)

---

## 3. Pointing the virtual network at the DC

This is the step that silently breaks the lab if skipped. Azure-provided DNS at
168.63.129.16 knows nothing about `sindredg.local`, so a join attempted before this
fails with a "domain not found" message that reads like a credentials problem.

From the workstation rather than the VM, in `terraform/azure/terraform.tfvars`:

```hcl
dns_servers = ["10.10.1.4"]
```

```bash
terraform apply
```

![Terraform applying the DNS change](images/phase1/vnet-dns-apply.png)

One resource changed, nothing added or destroyed.

**Restart CS01.** This is required rather than advisable: a VNet DNS change is only
picked up when the NIC re-reads DHCP, which in practice means a reboot. Applying
the Terraform change alone leaves CS01 still pointed at Azure DNS.

```bash
az vm restart -g rg-hybridid-swedencentral -n CS01
```

```powershell
ipconfig /all
```

![CS01 network configuration](images/phase1/cs01-ipconfig.png)

`DNS Servers: 10.10.1.4` rather than `168.63.129.16` is the confirmation. The blank
Primary DNS Suffix shows it is not joined yet.

**DNS resolving is not the same as the domain being usable.** Check that CS01 can
locate a domain controller through the SRV records, which is the same lookup the
join itself will use:

```powershell
Resolve-DnsName sindredg.local
nltest /dsgetdc:sindredg.local
```

![Domain controller located from CS01](images/phase1/cs01-resolve-dc.png)

`DC01.sindredg.local` at `10.10.1.4`, advertising `PDC GC DS LDAP KDC TIMESERV
WRITABLE`.

> **Start DC01 first, every session.** The auto-shutdown schedule stops the VMs
> nightly. Now that the VNet points at 10.10.1.4 for DNS, starting another machine
> while DC01 is deallocated leaves it with no name resolution at all, including for
> the internet. It presents as a comprehensively broken machine rather than a
> missing domain controller.

---

## 4. Joining CS01 to the domain

The credential has a non-obvious answer. Promotion migrated the local `labadmin`
account into the directory and made it the **sole member of Domain Admins**, so
that is what authenticates the join.

```powershell
Add-Computer -DomainName sindredg.local -Credential (Get-Credential SINDREDG\labadmin) -Restart
```

```powershell
Get-ComputerInfo -Property CsDomain, CsDomainRole
```

![CS01 joined to the domain](images/phase1/cs01-domain-joined.png)

`sindredg.local` and `MemberServer`. CS01 now has RSAT available, which is the
comfortable way to administer a Server Core domain controller from here on.

---

## 5. Building the directory

The initial password is prompted for rather than passed on the command line, so it
does not land in shell history.

```powershell
.\02-ad-structure.ps1 -DomainName sindredg.local -InitialPassword (Read-Host -AsSecureString 'Initial user password')
```

![Invoking the structure script](images/phase1/ad-structure-invocation.png)

![First run creates everything](images/phase1/ad-structure-first-run.png)

Six OUs, four groups, five users, each added to its group. Users are created
**disabled** on purpose, so the sync scope can be reviewed before any account is
usable. Re-run with `-EnableUsers` once it is confirmed.

Entra Connect gets scoped to `OU=Sync` in Phase 2, so `ServiceAccounts` under
`NoSync` is what demonstrates the filtering actually works.

A second run changes nothing:

![Second run reports exists](images/phase1/ad-structure-idempotent.png)

That idempotency check is the closest the PowerShell layer gets to `terraform
plan`. The scripts check every attribute they claim to manage, not just whether an
object exists, which they acquired the hard way; see the troubleshooting log.

---

## 6. Preparing the directory for sync

The forest is `sindredg.local`. The tenant's only verified domain is
`<tenant>.onmicrosoft.com`. Because `.local` cannot be verified in
Entra, users created with a `@sindredg.local` UPN would sync under the tenant
default anyway. Fixing it on-premises first is exactly the remediation a real
`.local` migration performs.

The pre-flight runs in report-only mode. Nothing changes without `-Apply`.

```powershell
.\03-prep-sync.ps1 -UpnSuffix <tenant>.onmicrosoft.com -DomainName sindredg.local
```

![Pre-flight, report only](images/phase1/prep-sync-report.png)

`MISSING` for the suffix and `WOULD` for each user. The bad-suffix check is
deliberately suppressed in report mode: before `-Apply` every user is legitimately
still on `@sindredg.local`, so flagging them would be noise.

Then applied, which adds the onmicrosoft domain as an alternative UPN suffix on the
forest and retargets each seed user:

```powershell
.\03-prep-sync.ps1 -UpnSuffix <tenant>.onmicrosoft.com -DomainName sindredg.local -Apply
```

Confirmed directly against the directory:

```powershell
Get-ADUser -Filter * -SearchBase 'OU=Users,OU=Sync,DC=sindredg,DC=local' |
  Select-Object SamAccountName, UserPrincipalName
```

![UPNs retargeted](images/phase1/upns-retargeted.png)

A re-run against the already-correct directory converges cleanly: the suffix
reports `exists`, every user reports `ok`, and the blockers section is empty.

![Clean re-run](images/phase1/prep-sync-clean.png)

The script also checks the three things that most commonly cause a user to fail
synchronisation later, when the error surfaces hours after the cause:

| Check | Why it blocks sync |
|---|---|
| Missing `givenName` or `sn` | Some Entra Connect sync rules reject the object outright |
| Duplicate `proxyAddresses` | Entra treats the address as tenant-unique. The single most common cause of a user silently not appearing |
| UPN suffix not verified in Entra | The account falls back to the tenant default, which is confusing rather than broken |

---

## 7. Exit criteria

| Criterion | Command | Status |
|---|---|---|
| Forest healthy | `dcdiag /q` returns nothing | Done |
| SYSVOL shared | `net share` lists SYSVOL and NETLOGON | Done |
| DNS answering | `Resolve-DnsName sindredg.local` from CS01 | Done |
| CS01 joined | `Get-ComputerInfo -Property CsDomainRole` reads `MemberServer` | Done |
| Users present and enabled | `Get-ADUser` in `OU=Users,OU=Sync` | Done |
| UPNs routable | Every seed user ends `@<tenant>.onmicrosoft.com` | Done |
| No sync blockers | `03-prep-sync.ps1` reports zero issues | Done |

`dcdiag /q` printing nothing at all is success. It only reports failures.

---

## Next

[Phase 2](02-entra-connect.md) installs Entra Connect Sync on CS01 and
synchronises the five seeded users into Microsoft Entra ID. Sync is free with any
Azure subscription.
