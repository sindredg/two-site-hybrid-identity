# Risk and limitations

What this lab does not do safely, and what would have to change if it stopped
being a single-operator prototype. Recorded rather than pretended away.

---

## 1. State

| Issue | Impact | Fix outside a prototype |
|---|---|---|
| Local backend | No locking. Two concurrent applies would corrupt state | `azurerm` backend with blob lease locking |
| No versioning | A bad write is unrecoverable beyond `terraform.tfstate.backup` | Storage account with blob versioning and soft delete |
| Single copy | Losing the machine orphans 13 billed Azure resources with no way to `destroy` them | Remote state, or at minimum an off-machine copy |
| File mode `0644` | World-readable on a multi-user system | `chmod 600` as the minimum |

The local backend is documented as suitable for solo prototypes only, which this
is. The gap is real regardless.

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
`.gitignore`. Verify with `git check-ignore -v` before any first commit to a new
clone.

---

## 3. One password across every VM

The same local administrator credential is used on DC01, CS01 and CL01, and
becomes the Domain Admin password after promotion. Convenient for a lab, and
exactly the flat-credential pattern that hybrid identity work is supposed to
argue against.

Out of scope here. Worth naming, because a reader will notice.

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

```bash
terraform providers lock -platform=linux_arm64 -platform=linux_amd64 -platform=windows_amd64
```

---

## 6. Security posture of the lab tenant

Security defaults were disabled in this tenant during an earlier project to
unblock Azure CLI authentication. An identity lab whose own tenant runs without
MFA undercuts the exercise.

**Intended fix:** replace with a Conditional Access policy in Phase 4, once P1 is
available, and re-enable MFA for the administrator account. Tracked as an open
item rather than closed.

---

## 7. Default outbound access

With the public IPs removed, the VMs reach the internet through Azure's implicit
outbound access, confirmed by `defaultOutboundAccess: true` on the subnet. That
address is Azure-owned, can change, and Microsoft is moving new virtual networks
to private-by-default.

If this VNet is ever rebuilt, outbound may need an explicit NAT Gateway. Entra
Connect cannot reach Entra ID without it, so the failure would be total rather
than partial.
