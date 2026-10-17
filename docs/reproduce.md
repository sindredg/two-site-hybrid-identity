# Rebuild and operate the lab

The environment has been torn down. These instructions preserve the original build path; they
have not been rerun for this documentation update. Terraform creates the Azure resources. The
[phase walkthroughs](PLAN.md) add the forest, synchronization, device registration, and policies;
applying Terraform alone does not reproduce the identity configuration.

## Before you begin

Use Terraform and Azure CLI from WSL. Check current regional VM quotas, image availability,
Entra Connect requirements, and the [risk register](risk-and-limitations.md) before deploying.
Both sites use DC01 for DNS after forest setup, so start DC01 before the other VMs.

The original subnets relied on Azure's implicit outbound access. For a new deployment, review
[explicit outbound connectivity](risk-and-limitations.md#7-default-outbound-access-on-two-subnets-now)
for updates, downloads, and Entra registration. Each Terraform root has local state containing
provisioning credentials; keep it private and backed up. `sensitive = true` does not encrypt state.

## Apply the infrastructure

From the repository root:

```bash
cd terraform/azure
az login
```

Set `subscription_id` in your local `terraform.tfvars`. Supply the required VM provisioning
password through the environment, without committing it:

```bash
read -rsp 'VM admin password: ' TF_VAR_admin_password
export TF_VAR_admin_password
echo
terraform init
terraform plan
terraform apply
```

Review the plan before applying. VM replacement can destroy a configured domain controller;
Terraform does not reconstruct its directory contents.

Complete [forest setup](01-ad-environment.md) and [Entra sync](02-entra-connect.md) before
adding the branch, following the original phase order. The branch root reads the HQ network and
owns both peering objects. Copy its variable example:

```bash
cd ../azure-denmarkeast/branch
cp terraform.tfvars.example terraform.tfvars
```

Set the subscription and review client settings in the local file before planning:

```bash
terraform init
terraform plan
terraform apply
```

The same shell retains `TF_VAR_admin_password`; choose provisioning credentials deliberately and
keep both roots' state out of Git. The original shared credential was later replaced by LAPS on
member machines and a separate domain break-glass credential.

## Build the identity layers

Follow the [phase index](PLAN.md) in order. Infrastructure, directory, and endpoint settings are
separate stages:

| Stage | Walkthrough |
| --- | --- |
| HQ infrastructure and AD forest | [Phase 0](00-infrastructure.md), [Phase 1](01-ad-environment.md) |
| Scoped Entra synchronization | [Phase 2](02-entra-connect.md) |
| Branch network, AD sites, and hybrid join | [Phase 3](03-branch-network.md), [Phase 4](04-hybrid-join.md) |
| Group Policy and baseline comparison | [Phase 5](05-group-policy.md), [Phase 6](06-security-baselines.md) |
| LAPS and tiered administration | [Phase 7](07-windows-laps.md), [Phase 8](08-tiered-administration.md) |

Use each phase's checks before continuing. Some settings require GPMC or the Entra Connect
wizard; directory bootstrap scripts are under [`scripts/ad-bootstrap/`](../scripts/ad-bootstrap/).
Tiered logon policy can lock out administrators. Follow the Phase 8 recovery preparation and
link one policy at a time. Its documented test gaps remain gaps, even though the phase is closed.

## Connect and manage cost

Run `terraform output bastion_connect_urls` from either root. The HQ Bastion reaches the branch
through peering; branch access therefore depends on both sites being available.

HQ has VM auto-shutdown schedules. The branch clients were deallocated manually because the
shutdown resource was unavailable in that region during the lab. Stopping Windows alone does not
deallocate the Azure VM:

```bash
az vm deallocate --resource-group rg-branch-office --name CL01
az vm deallocate --resource-group rg-branch-office --name CL02
```

Bastion bills while provisioned. The HQ root's `enable_bastion` switch controls that resource;
review a plan before changing it. See [cost decisions](decisions.md#reaching-the-vms) and
[VM operating commands](../cmd-sheets/azure-cli.md).

## Tear down

Destroy the branch first because its state owns peering objects in both VNets:

```bash
cd terraform/azure-denmarkeast/branch
terraform plan -destroy
terraform destroy
cd ../../azure
terraform plan -destroy
terraform destroy
```

These paths start from the repository root. Do not delete either state file until its resources
are gone. Terraform removes the Azure resources it owns; directory and tenant objects created
through PowerShell or the Entra Connect wizard need their own reviewed cleanup.
