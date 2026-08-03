# Phase 3. Hybrid Entra join

> **Status: Pending.** Not yet executed. Written from documented behaviour, to be
> rewritten as a record with screenshots once run.

**Goal:** get CL01 and CL02 joined to both directories at once, which is the
precondition for backing a LAPS password up to Entra ID in Phase 6.

> Configured through the Microsoft Entra Connect wizard on CS01. See
> [Configure Microsoft Entra hybrid join](https://learn.microsoft.com/entra/identity/devices/how-to-hybrid-join).

**Why this matters.** A hybrid-joined device has an identity in Active Directory
and a registration in Entra ID simultaneously. That dual state is what makes the
final phase interesting: policy arrives from on-premises Group Policy while the
secret it manages is stored in the cloud.

**No licence required.** Hybrid join is free. Only the Conditional Access that
would normally consume the device state needs P1, and that is where this lab stops.

---

## 1. Prerequisites

| Requirement | Detail |
|---|---|
| Entra Connect Sync installed | Phase 2, version 1.1.819.0 or later for the wizard |
| Computer objects in sync scope | `OU=Workstations,OU=Sync` must be selected in Connect Sync |
| Default device attributes not excluded | Excluding them breaks device registration in ways that surface much later |
| Hybrid Identity Administrator | Entra side of the wizard |
| Enterprise Admin | On-premises side |

Devices need outbound access to these endpoints. All four work through the
subnet's default outbound access, so no NSG change is needed:

```
https://enterpriseregistration.windows.net
https://login.microsoftonline.com
https://device.login.microsoftonline.com
https://autologon.microsoftazuread-sso.com
```

---

## 2. Steps

1. Set `enable_client = true` in `terraform/azure/terraform.tfvars` and apply.
   Expect CL01 and CL02, their NICs, disks and shutdown schedules
2. Restart both clients so they take DC01 as DNS, then join them to
   `sindredg.local` as `SINDREDG\labadmin`
3. Move both computer objects into `OU=Workstations,OU=Sync`
4. Confirm the objects sync to Entra, since hybrid join depends on it
5. Run the hybrid join wizard in Entra Connect on CS01
6. Restart the clients and wait for the scheduled device registration task

---

## 3. Verification

```powershell
dsregcmd /status
```

| Field | Expected |
|---|---|
| `AzureAdJoined` | YES |
| `DomainJoined` | YES |
| `DeviceId` | Present, and matching the object in the Entra portal |
| `TenantName` | The tenant |

Both devices should appear in the Entra admin center under Devices with join type
**Microsoft Entra hybrid joined**.

`AzureAdJoined: NO` with `DomainJoined: YES` usually means the computer object has
not synced yet, or the device could not reach one of the registration endpoints.

---

## 4. Exit criteria

| Criterion | Status |
|---|---|
| CL01 and CL02 domain-joined | Pending |
| Computer objects in `OU=Workstations` and synced | Pending |
| `dsregcmd /status` shows both joins on both clients | Pending |
| Both listed as hybrid joined in the portal | Pending |

---

## Next

[Phase 4](04-group-policy.md) builds the Group Policy estate that these clients
will receive.
