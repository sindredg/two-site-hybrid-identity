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

## 4. CI checks syntax, nothing reviews intent

`.github/workflows/terraform.yml` runs on every push and pull request:

| Check | Scope |
|---|---|
| `terraform fmt -check -recursive` | Repo root, so both roots and the shared module |
| `terraform validate` | Each root separately, as a matrix |

That catches formatting drift, syntax errors, bad references and type mismatches
before they land. It is a real gate and it did not exist before.

**What it still does not do.** No `plan`, so nothing reviews what a change would
actually do to live infrastructure. No policy check. No second pair of eyes on an
apply.

**The missing `plan` is a deliberate trade, not an oversight.** Running one in CI
needs Azure credentials stored as repository secrets. For a lab whose state already
holds a plaintext administrator password, adding cloud credentials to GitHub buys a
marginal review gain for a real increase in blast radius. The honest position is
that every apply is still local, manual, and reviewed only by whoever is reading
the terminal.

Outside a prototype the answer is a service principal scoped to one subscription,
OIDC federation rather than a stored secret, and `plan` posted to the pull request
for review before a gated apply.

---

## 5. The provider lock file, checked and not a problem

**This entry was wrong and is kept as a correction rather than deleted.**

It previously claimed `.terraform.lock.hcl` recorded hashes for `linux_arm64` only,
and that a clone on any other OS would fail `init` with a checksum error.

Both lock files hold one `h1:` hash and **twelve `zh:` hashes**. Those two kinds are
not the same thing:

| Hash | What it covers |
|---|---|
| `h1:` | A directory hash of the extracted package, for the one platform installed locally |
| `zh:` | The registry-signed zip hash, one per platform the provider publishes |

Twelve `zh:` entries means every published platform can be verified on download, so
a clone on Windows or amd64 Linux initialises normally.

Confirmed rather than assumed. Running the fix the old entry recommended:

```bash
terraform providers lock -platform=linux_arm64 -platform=linux_amd64 -platform=windows_amd64
```

reported `Terraform has validated the lock file and found no need for changes` in
both roots, which is Terraform stating directly that nothing was missing.

**Where the original advice does apply.** A lock file built from a local filesystem
mirror carries `h1:` hashes only, with no `zh:` entries, and then the platform
problem is real. Built from the public registry, as these were, coverage is
automatic.

The CI added in entry 4 now proves this on every push: the runner is `linux_amd64`
and initialises from these lock files without complaint.

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

**The Group Policy half is now delivered.** Phase 5's `User-Standard` carries the
Site to Zone Assignment List entry that lets a browser send its Kerberos ticket to
the Entra endpoint, which is what makes Seamless SSO function rather than merely
exist. The key rotation above stays open and unautomated.

---

## 9. AD Recycle Bin, enabled in Phase 5

**Closed.** Flagged by the Entra Connect wizard on its completion page. Without it,
a deleted user, group or OU was recoverable only from a system state backup, and
this lab has no backup at all.

```powershell
Enable-ADOptionalFeature 'Recycle Bin Feature' -Scope ForestOrConfigurationSet -Target sindredg.local
```

**It is irreversible**, which is why it is off by default and why it was worth a
moment's thought rather than a reflex. For a lab where every object was created by
a script and could be recreated by re-running it, the case is weaker than in
production. The case *for* enabling it is that Phase 7 extends the schema and
Phase 8 restructures OUs, and an accidental deletion during either would otherwise
be unrecoverable. That decided it.

Evidence and the confirmation prompt are in
[05-group-policy.md](05-group-policy.md).
