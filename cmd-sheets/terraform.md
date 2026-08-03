# Terraform

Run from the workstation, in WSL. The `azurerm` provider has no ARM64 Windows
build, which is why this is not run from PowerShell.

## Roots

| Root | Holds |
|---|---|
| `terraform/azure` | HQ: network, DC01, CS01, Bastion |
| `terraform/azure-denmarkeast/branch` | Branch: network, peering, CL01, CL02 |
| `terraform/modules/windows-vm` | Shared VM module, no state of its own |

Apply HQ first. The branch reads the HQ network through a data source and creates
both peering objects.

## The password never goes in a file

```bash
read -rsp 'VM admin password: ' TF_VAR_admin_password && export TF_VAR_admin_password && echo
```

Once per shell session. Use the same value for both roots, since the machines join
the same domain.

## Everyday

```bash
cd terraform/azure
```

```bash
terraform init
```

```bash
terraform plan
```

```bash
terraform apply
```

```bash
terraform output
```

## Before a risky apply

Save the plan and read it rather than trusting the summary line:

```bash
terraform plan -out=tf.plan
```

```bash
terraform show tf.plan | grep "^  # "
```

That prints one line per resource action. Anything reading `must be replaced`
against a VM should stop the apply.

## Formatting and validation

```bash
terraform fmt -recursive
```

```bash
terraform validate
```

## State inspection

```bash
terraform state list
```

```bash
terraform state show azurerm_windows_virtual_machine.vm
```

## Provider lock file

Generated on one platform by default, which breaks a clone elsewhere with a
checksum error rather than a missing-package error:

```bash
terraform providers lock -platform=linux_arm64 -platform=linux_amd64 -platform=windows_amd64
```

## Tearing down

Branch first, because it owns the peering objects that reach into the HQ group:

```bash
cd terraform/azure-denmarkeast/branch
```

```bash
terraform destroy
```

## Cost control

Bastion bills hourly while it exists. Set `enable_bastion = false` in
`terraform/azure/terraform.tfvars` and apply when finished for the day.

Set `enable_client = false` in `terraform/azure-denmarkeast/branch/terraform.tfvars` to remove the
clients while keeping the network and peering in place.
