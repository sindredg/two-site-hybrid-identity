# Risk and limitations

What this lab does not do safely, and what would have to change if it stopped
being a single-operator prototype. Recorded rather than pretended away.

---

## 1. State

| Issue | Impact | Fix outside a prototype |
|---|---|---|
| Local backend | No locking. Two concurrent applies would corrupt state | `azurerm` backend with blob lease locking |
| No versioning | A bad write is unrecoverable beyond `terraform.tfstate.backup` | Storage account with blob versioning and soft delete |
| Single copy | Losing the machine orphans every billed Azure resource with no way to `destroy` them | Remote state, or at minimum an off-machine copy |
| File mode `0644` | World-readable on a multi-user system | `chmod 600` as the minimum |
| **Two state files now** | Phase 3 added `terraform/azure-denmarkeast/branch/`. Every issue above applies twice, to two files that must both survive | Same fix, applied to both roots |

The local backend is documented as suitable for solo prototypes only, which this
is. The gap is real regardless, and splitting the lab into two roots doubled the
surface without changing the nature of it.

---

## 2. The admin password is in state, in plaintext

`azurerm_windows_virtual_machine.admin_password` is written to
`terraform.tfstate` unencrypted. `sensitive = true` masks CLI display and does
nothing to storage.

Two consequences:

- **Anyone who can read state can read the credential.** State readers are secret
  readers. This is why the file must never be committed
- **The password is ForceNew.** A mismatch plans a destroy and recreate of both
  VMs, including a promoted domain controller. If a plan shows
  `azurerm_windows_virtual_machine` as `-/+ must be replaced`, stop

`terraform.tfstate` and `terraform.tfvars` are covered by the repository
`.gitignore` in every root. Verify with `git check-ignore -v` before any first
commit to a new clone.

**The same password is now in two state files**, since the branch machines join the
same domain and need the same local administrator credential. Either file leaking
is equivalent to both.

**Checked, and not fixable in the provider.** azurerm 4.81 offers no write-only
variant of `admin_password`, confirmed against the provider schema. Terraform 1.11
introduced write-only arguments precisely for this, but the resource does not
implement one, so this cannot be solved in the configuration.

---

## 3. One password across every VM

The same local administrator credential is used on every machine, and becomes the
Domain Admin password after promotion. Convenient for a lab, and
exactly the flat-credential pattern that endpoint hardening exists to argue
against.

**No longer out of scope.** Phase 6 deploys Windows LAPS, which gives every
machine its own rotating local administrator password stored encrypted in Active
Directory. Phase 7 splits the single Domain Admin account into a tiered model.
This entry stays open until both are done, and closing it is the point of those
phases rather than a side effect.

---

## 4. No CI, no review gate

Every apply is local and manual. Nothing enforces `fmt`, `validate`, a policy
check, or a second pair of eyes before infrastructure changes.

For a solo lab this is proportionate. The honest version is that the plan output
in the terminal is the only review this code gets.

---

## 5. The provider lock file covers one platform

`.terraform.lock.hcl` was generated on `linux_arm64` and records hashes for that
platform only. A clone on another OS fails `init` with a checksum error rather
than a missing-package error, which reads as a different problem.

**Both roots have this**, since `terraform/azure-denmarkeast/branch/` generated its own lock file the
same way. Run it in each:

```bash
terraform providers lock -platform=linux_arm64 -platform=linux_amd64 -platform=windows_amd64
```

---

## 6. Security posture of the lab tenant

Security defaults were disabled in this tenant during an earlier project to
unblock Azure CLI authentication. An identity lab whose own tenant runs without
MFA undercuts the exercise.

**Intended fix:** replacing security defaults with an equivalent Conditional Access
policy is the textbook answer and is not reachable here, since that needs P1. The
remaining honest options are to re-enable security defaults and accept the MFA
prompt on the Azure CLI, or to leave them off and say so plainly, which is what
this entry does. Tracked as open rather than closed.

---

## 7. Default outbound access

With the public IPs removed, the VMs reach the internet through Azure's implicit
outbound access, confirmed by `defaultOutboundAccess: true` on the subnet. That
address is Azure-owned, can change, and Microsoft is moving new virtual networks
to private-by-default.

If this VNet is ever rebuilt, outbound may need an explicit NAT Gateway. Windows
Update, the Security Compliance Toolkit download, and activation all depend on it,
so the failure would be broad rather than subtle.

---

## 8. The Seamless SSO key needs rotating every 30 days, by hand

Enabling Seamless SSO in Phase 2 created a computer account, `AZUREADSSOACC`, in
the forest. Microsoft is blunt about what its Kerberos decryption key is:

> The Kerberos decryption key on a computer account, if leaked, can be used to
> generate Kerberos tickets for any synchronized user. Malicious actors can then
> impersonate Microsoft Entra sign-ins for compromised users.

That is a skeleton key for every synced identity. It should be rolled **at least
every 30 days**, and nothing does it for you:

```powershell
Import-Module 'C:\Program Files\Microsoft Azure Active Directory Connect\AzureADSSO.psd1'
New-AzureADSSOAuthenticationContext
$creds = Get-Credential
Update-AzureADSSOForest -OnPremCredentials $creds
```

Run it more than once per forest in a session and Seamless SSO breaks until
existing tickets expire.

**Two related obligations:**

The account should use **AES256**, not `RC4_HMAC_MD5`. The July 2026 Windows
Server update changes the default Kerberos encryption type in AD DS from RC4 to
AES-256, and an account still on RC4 when that lands can stop working. The key
must be rolled *before* changing encryption type, not after.

The account itself should be protected: manageable only by Domain Admins, Kerberos
delegation disabled on it, and parked in an OU where it will not be deleted by
accident.

**Why this is an open risk rather than a closed task.** A manual 30-day rotation
with no expiry warning and no enforcement is the kind of thing that lapses
silently. Seamless SSO was enabled for demonstration value and because it gives
Phase 5 a real Group Policy task, not because this lab needs it. If the rotation
is not going to happen, the honest options are to accept the risk explicitly or to
disable the feature.

---

## 9. AD Recycle Bin is not enabled

Flagged by the Entra Connect wizard on its completion page. Without it, a deleted
user, group or OU is recoverable only from a system state backup, and this lab has
no backup at all.

```powershell
Enable-ADOptionalFeature 'Recycle Bin Feature' -Scope ForestOrConfigurationSet -Target sindredg.local
```

**It is irreversible**, which is why it is off by default and why it is worth a
moment's thought rather than a reflex. For a lab where every object was created by
a script and could be recreated by re-running it, the case is weaker than in
production. The case *for* enabling it is that Phase 7 extends the schema and
Phase 8 restructures OUs, and an accidental deletion during either would otherwise
be unrecoverable.

Carried into Phase 5.
