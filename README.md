# Hybrid identity across two sites: AD DS and Microsoft Entra ID

An Active Directory forest served endpoints in a second Azure region and synchronized identities
to Microsoft Entra ID. Group Policy delivered endpoint settings, Windows LAPS rotated local
administrator passwords, and separate admin accounts exercised tiered logon controls.

> **Completed lab; environment torn down.** Results and screenshots record the original tests.
> The walkthroughs retain their versions, failures, and evidence limits.

## How it fits together

![Hybrid identity overview: the HQ and branch Azure VNets communicate over global VNet peering. DC01 provides AD DS, DNS, and Group Policy. CS01 reads the directory and synchronizes identities to Entra over HTTPS. Both branch clients register with Entra; CL01 backs up its LAPS password to AD DS and CL02 to Entra. CS01 also uses AD-backed LAPS.](docs/diagrams/identity-overview.svg)

- **Local directory and policy:** DC01 supplies AD DS, DNS, and Group Policy. Branch clients
  reach it across global VNet peering. CS01 hosts Entra Connect Sync and the policy-management
  tools; directory objects, GPOs, and filtering determine what each machine receives.
- **Cloud identity:** Connect Sync synchronizes users and device objects, with password hash
  sync for cloud sign-in. Hybrid join also requires each client to complete its own registration
  with Entra. Directory synchronization and device registration are separate steps.
- **Endpoint controls:** CL01 received the Server 2022 member-server baseline; CL02 was its
  comparison control. Both received LAPS policy from AD. CL01 and CS01 backed up encrypted
  passwords to AD DS; CL02 backed up to Entra. Each machine uses one LAPS backup directory.
- **Administration:** workload VMs had no public IPs. One Azure Bastion in the HQ VNet reached
  both sites. Tier 0, 1, and 2 accounts had separate responsibilities and GPO-based deny-logon
  rights; the evidence below shows which paths were exercised.

Terraform defines the two Azure footprints. PowerShell builds the directory structure, and
Group Policy configures the endpoints. The [decisions](docs/decisions.md) explain those boundaries
and link to the relevant Microsoft documentation.

## What was verified

| Behavior checked | Observed result | Evidence |
| --- | --- | --- |
| Directory sync and scope | Five seed users appeared in Entra; service accounts in `NoSync` stayed out | [Sync verification](docs/02-entra-connect.md#verification) |
| Hybrid join | Both branch clients completed AD domain join and Entra registration | [Device registration](docs/04-hybrid-join.md#device-registration), [Entra verification](docs/04-hybrid-join.md#verification) |
| Group Policy delivery | Client reports and the active firewall rule confirmed policy; an inbound ping began working after refresh | [Before and after](docs/05-group-policy.md#verification-the-policy-reaching-a-client) |
| LAPS access and rotation | Authorized decryption and a forced password rotation succeeded; a captured Domain Admin read returned `Unauthorized` | [AD access check](docs/07-windows-laps.md#retrieval-active-directory), [positive check and rotation](docs/08-tiered-administration.md#closing-phase-7s-outstanding-verifications) |
| Tiered administration | Own-tier sessions worked; the captured cross-tier `runas` attempts returned logon error `1385` | [Positive path](docs/08-tiered-administration.md#the-positive-path-before-anything-is-denied), [refusal matrix](docs/08-tiered-administration.md#the-refusals) |

## Limits that matter

- **Policy comparison:** the baseline comparison used Group Policy Modeling, supported by
  observed endpoint behavior. A Policy Analyzer comparison of effective machine state was
  [not completed](docs/06-security-baselines.md#why-policy-analyzer-was-abandoned).
- **Partial tier-test coverage:** not every account/machine pair was tested. Event-log correlation
  and network-logon denial were [not captured](docs/08-tiered-administration.md#what-is-not-captured).
- **Privileged recovery paths:** Azure VM administration can execute as SYSTEM outside AD logon
  controls, and the break-glass account is exempt from tier denies. LAPS decryption restrictions
  do not prevent a Domain Admin from changing policy. See the
  [risk register](docs/risk-and-limitations.md) and [LAPS decision](docs/decisions.md#who-can-read-a-machines-password).
- **Rebuild assumptions:** local Terraform state contains provisioning credentials, and the
  original subnets used implicit outbound access. A rebuild needs reviewed state protection and
  outbound connectivity; see [state handling](docs/risk-and-limitations.md#2-the-admin-password-is-in-state-in-plaintext)
  and [outbound access](docs/risk-and-limitations.md#7-default-outbound-access-on-two-subnets-now).

The identity features used Entra ID Free. Conditional Access, PIM, and access reviews are covered
separately in [Access Control and Identity Governance](https://github.com/sindredg/Access-Control-and-Identity-Governance).

## Find your way around

| To understand | Start here |
| --- | --- |
| The build, phase by phase, with exit criteria and screenshots | [Phase index](docs/PLAN.md) |
| How to rebuild, connect, and shut down | [Reproduction guide](docs/reproduce.md) |
| Commands grouped by tool and task | [Command sheets](cmd-sheets/README.md) |
| Why the design uses these tools and boundaries | [Decisions](docs/decisions.md) |
| Failures, diagnostic steps, and fixes | [Troubleshooting index](docs/troubleshooting/README.md) |
| What the controls leave exposed | [Risk register](docs/risk-and-limitations.md) |
| The infrastructure and directory code | [HQ](terraform/azure/), [branch](terraform/azure-denmarkeast/branch/), [directory bootstrap](scripts/ad-bootstrap/) |
