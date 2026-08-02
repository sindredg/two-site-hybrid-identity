# Phase 1. Active Directory environment

**Goal:** promote DC01 to a new forest, point the virtual network at it, join CS01
to the domain, and build a directory structure realistic enough that scoped
synchronisation is a meaningful thing to demonstrate in Phase 2.

> The three scripts live in `scripts/ad-bootstrap/` and are idempotent: a second
> run reports what already exists and changes nothing. See
> [Install a new Active Directory forest](https://learn.microsoft.com/windows-server/identity/ad-ds/deploy/install-a-new-windows-server-2012-active-directory-forest--level-200-)
> and [Microsoft Entra Connect prerequisites](https://learn.microsoft.com/entra/identity/hybrid/connect/how-to-connect-install-prerequisites).

**Why this matters.** Everything after this depends on it. Entra Connect has
nothing to synchronise without a directory, hybrid join has no domain to join,
and Conditional Access has no on-premises identities to make decisions about. The
directory structure also decides what Phase 2 can show: an unfiltered sync of
five users proves very little, whereas a scoped sync that deliberately excludes
service accounts demonstrates a real design choice.

**Trade-off from best practice.** Two things here are weaker than production.
`sindredg.local` is not routable and cannot be verified in Entra, so the forest
domain and the UPN suffix differ and the users need retargeting before sync; see
[decisions](decisions.md). And a single local administrator credential is reused
across all three VMs and becomes Domain Admin after promotion, which is the flat
credential pattern hybrid identity work exists to argue against; see
[risk and limitations](risk-and-limitations.md).

---

## What gets created

| Object | Name | Purpose |
|---|---|---|
| Forest | `sindredg.local` (NetBIOS `SINDREDG`) | The domain, with DNS on DC01 |
| OU | `OU=Sync` | Everything Entra Connect will be scoped to |
| OU | `OU=Users,OU=Sync` | Synced user accounts |
| OU | `OU=Groups,OU=Sync` | Synced security groups |
| OU | `OU=Workstations,OU=Sync` | Domain-joined devices, used in Phase 3 |
| OU | `OU=NoSync` | Deliberately outside the sync scope |
| OU | `OU=ServiceAccounts,OU=NoSync` | Proves filtering works by being absent from Entra |

| Group | Intended use |
|---|---|
| `sg-finance` | Conditional Access target in Phase 4 |
| `sg-it-admins` | Will require a hybrid joined device |
| `sg-helpdesk` | Access review target in Phase 5 |
| `sg-contractors` | Stricter policy target |

| User | Department | Title | Group |
|---|---|---|---|
| `alindqvist` | Finance | Financial Controller | `sg-finance` |
| `bkarlsson` | Finance | Analyst | `sg-finance` |
| `cdubois` | IT | Systems Engineer | `sg-it-admins` |
| `dvolkov` | IT | Service Desk Analyst | `sg-helpdesk` |
| `erossi` | External | Contractor | `sg-contractors` |

Departments and titles are populated deliberately. Entra Connect synchronises
them, and Phase 4 can then target Conditional Access on an attribute rather than
a hand-maintained group.

---

## 1. Promote DC01

**1.** We connect to DC01. There are no public IPs, so this is a browser session
through Bastion.

```bash
cd terraform/azure
terraform output bastion_connect_urls
```

Open the DC01 URL, choose **Bastion**, and sign in with the local administrator
credentials from the Phase 0 deploy.

![Bastion connection to DC01](images/phase1/bastion-connect-dc01.png)

DC01 runs Server Core, so we land on a command prompt rather than a desktop. That
is the image working as intended, not a broken install. Type `powershell` to get a
real shell.

![Server Core command prompt](images/phase1/dc01-server-core-prompt.png)

**2.** We get the script onto the box. The Bastion Developer SKU has no file
transfer, but the web client supports copy and paste, so we open the clipboard
panel and paste the contents of `01-promote-dc.ps1` into a new file:

```powershell
notepad C:\promote.ps1
```

For a first run it is worth typing the two real commands instead, because the
script is a thin wrapper around them and watching each one land teaches more than
watching a wrapper scroll past.

**3.** We install the role. This is quick and changes nothing about the machine's
identity yet.

```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
```

![AD DS role installed](images/phase1/install-addsrole.png)

**4.** We create the forest. This is the irreversible step.

```powershell
Install-ADDSForest -DomainName sindredg.local -DomainNetbiosName SINDREDG -InstallDns -Force
```

`-InstallDns` matters more than it looks. A domain controller has to answer the
SRV record lookups that clients use to find it: a machine that only knows the name
`sindredg.local` has no way to discover DC01's address unless something
authoritative for that zone answers. That is why the next section points the whole
virtual network at 10.10.1.4, and why the DC has to be its own DNS server first.

We are prompted for a **Directory Services Restore Mode** password. It is not the
same as the administrator password and it is not recoverable, so it goes in the
password manager now.

![DSRM password prompt](images/phase1/dsrm-prompt.png)

The machine reboots automatically on completion and the Bastion session drops.
Expected. Wait a couple of minutes and reconnect.

**5.** We confirm the forest exists.

```powershell
Get-ADDomain | Select-Object DNSRoot, NetBIOSName, DomainMode
Get-ADForest | Select-Object Name, ForestMode, GlobalCatalogs
```

![Forest created](images/phase1/get-addomain.png)

---

## 2. Point the virtual network at the DC

This is the step that silently breaks the lab if skipped. Azure-provided DNS at
168.63.129.16 knows nothing about `sindredg.local`, so a join attempted now fails
with a "domain not found" message that reads like a credentials problem.

**1.** We set the VNet DNS servers to the domain controller. From the workstation,
not the VM, edit `terraform/azure/terraform.tfvars`:

```hcl
dns_servers = ["10.10.1.4"]
```

```bash
terraform apply
```

Expect **1 to change**, the virtual network, and nothing else.

![Terraform applying the DNS change](images/phase1/terraform-dns-apply.png)

**2.** We restart CS01. A VNet DNS change is only picked up when the NIC re-reads
DHCP, and in practice that means a reboot. Applying the Terraform change alone
leaves CS01 still pointed at Azure DNS.

```bash
az vm restart -g rg-hybridid-swedencentral -n CS01
```

**3.** We verify from inside CS01, over Bastion:

```powershell
ipconfig /all
```

We want `10.10.1.4` as the DNS server. If `168.63.129.16` is still listed, the
reboot has not taken effect and joining will fail.

![CS01 resolving via the DC](images/phase1/cs01-ipconfig.png)

```powershell
Resolve-DnsName sindredg.local
nltest /dsgetdc:sindredg.local
```

`nltest` locating a domain controller is the real proof: it exercises the same SRV
lookup the join will use.

![Domain controller located from CS01](images/phase1/nltest-dsgetdc.png)

> **Start DC01 first, every session.** The auto-shutdown schedule stops all three
> VMs nightly. Now that the VNet points at 10.10.1.4 for DNS, starting CS01 while
> DC01 is deallocated leaves it with no name resolution at all, including for the
> internet. It presents as a comprehensively broken machine rather than a missing
> domain controller.

---

## 3. Join CS01 to the domain

**1.** On CS01, over Bastion:

```powershell
Add-Computer -DomainName sindredg.local -Credential (Get-Credential SINDREDG\labadmin) -Restart
```

![Domain join credential prompt](images/phase1/cs01-add-computer.png)

**2.** After the reboot we sign back in as a domain user and confirm:

```powershell
Get-ComputerInfo -Property CsDomain, CsDomainRole
```

`CsDomainRole` should read `MemberServer`.

![CS01 joined to the domain](images/phase1/cs01-joined.png)

CS01 now has RSAT available, which is the comfortable way to administer a Server
Core domain controller from here on.

---

## 4. Build the directory

**1.** We run the structure script on DC01. The initial password for the seed
users is prompted for rather than passed on the command line, so it does not land
in shell history.

```powershell
.\02-ad-structure.ps1 -DomainName sindredg.local -InitialPassword (Read-Host -AsSecureString 'Initial user password')
```

![OUs, groups and users created](images/phase1/ad-structure-run.png)

Users are created **disabled** by default. That is deliberate: it lets us confirm
the sync scope is correct before any account is usable.

**2.** We run it a second time, unchanged. Every object should report `exists` and
nothing should be created. This is the idempotency check, and it is the closest
thing the PowerShell layer has to `terraform plan`.

![Second run reports no changes](images/phase1/ad-structure-idempotent.png)

**3.** Once the structure looks right, we enable the accounts.

```powershell
.\02-ad-structure.ps1 -DomainName sindredg.local -InitialPassword (Read-Host -AsSecureString 'Initial user password') -EnableUsers
```

**4.** We confirm what landed:

```powershell
Get-ADUser -Filter * -SearchBase 'OU=Users,OU=Sync,DC=sindredg,DC=local' -Properties Department, Title |
    Format-Table SamAccountName, Name, Department, Title, Enabled
```

![Seed users in the Sync OU](images/phase1/get-aduser-sync.png)

---

## 5. Prepare the directory for sync

The forest is `sindredg.local`. The tenant's only verified domain is
`sindredemitriohotmail.onmicrosoft.com`. Because `.local` cannot be verified in
Entra, users created with a `@sindredg.local` UPN would sync under the tenant
default anyway. We fix that on-premises first, which is exactly the remediation a
real `.local` migration performs.

**1.** We run the pre-flight in report-only mode. Nothing is changed without
`-Apply`.

```powershell
.\03-prep-sync.ps1 -UpnSuffix sindredemitriohotmail.onmicrosoft.com -DomainName sindredg.local
```

The output shows the suffix that would be added and, for each user, the UPN
rewrite that would happen.

![Pre-flight report only](images/phase1/prep-sync-report.png)

**2.** We apply it.

```powershell
.\03-prep-sync.ps1 -UpnSuffix sindredemitriohotmail.onmicrosoft.com -DomainName sindredg.local -Apply
```

This adds the onmicrosoft domain as an alternative UPN suffix on the forest, then
retargets each seed user from `user@sindredg.local` to
`user@sindredemitriohotmail.onmicrosoft.com`.

![Suffix added and UPNs retargeted](images/phase1/prep-sync-apply.png)

**3.** The script also checks the three things that most commonly cause a user to
fail synchronisation later, when the error surfaces hours after the cause:

| Check | Why it blocks sync |
|---|---|
| Missing `givenName` or `sn` | Some Entra Connect sync rules reject the object outright |
| Duplicate `proxyAddresses` | Entra treats the address as tenant-unique. The single most common cause of a user silently not appearing |
| UPN suffix not verified in Entra | The account falls back to the tenant default, which is confusing rather than broken |

A clean run reports no blockers.

![No sync blockers](images/phase1/prep-sync-clean.png)

---

## Exit criteria

| Criterion | Command |
|---|---|
| Forest healthy | `dcdiag /q` returns nothing |
| DNS answering | `Resolve-DnsName sindredg.local` from CS01 |
| CS01 joined | `Get-ComputerInfo -Property CsDomainRole` reads `MemberServer` |
| Users present and enabled | `Get-ADUser -Filter * -SearchBase 'OU=Users,OU=Sync,DC=sindredg,DC=local'` |
| UPNs routable | Every seed user ends `@sindredemitriohotmail.onmicrosoft.com` |
| No sync blockers | `03-prep-sync.ps1` reports zero issues |

`dcdiag /q` printing nothing at all is success. It only reports failures.

![dcdiag clean](images/phase1/dcdiag.png)

---

## Next

Phase 2 installs Entra Connect Sync on CS01 and is blocked on licensing: the
tenant currently holds zero subscribed SKUs, and the P2 trial should be started
before that phase rather than during it.

Problems hit during this phase belong in [99-troubleshooting.md](99-troubleshooting.md).
