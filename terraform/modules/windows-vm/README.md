# windows-vm

One Windows VM plus the three things that always travel with it: a NIC, an OS disk
and a daily shutdown schedule.

A primitive module. It knows nothing about domains, sites or which network it is
attached to. The caller supplies a subnet and an address.

## Usage

The module sits at `terraform/modules/`, one level above the roots that call it, so
the source path depends on how deeply the caller is nested. From
`terraform/azure-denmarkeast/branch/` that is `../../modules/windows-vm`.

```hcl
module "clients" {
  source   = "../../modules/windows-vm"
  for_each = local.active_clients

  name                = each.key
  resource_group_name = azurerm_resource_group.branch.name
  location            = azurerm_resource_group.branch.location
  subnet_id           = azurerm_subnet.branch.id
  private_ip          = cidrhost(var.subnet_prefix, each.value.host_index)
  size                = var.client_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  tags                = var.tags
}
```

## What the validations are for

Each one is a failure this lab actually hit, or a documented Azure constraint that
fails late and confusingly rather than at plan time.

| Input | Rejects | Why |
|---|---|---|
| `name` | Over 15 characters, or symbols | Windows truncates silently, then the AD computer object does not match the machine |
| `size` | Arm64 sizes, the `p` variants | The x64 Windows images will not boot, and the error does not say so |
| `private_ip` | Anything that is not an IPv4 address | Typos surface as a provider error during apply, after other resources exist |
| `os_disk_size_gb` | Under 127 | The Windows Server images are 127 GB and a smaller disk is rejected at create time |
| `admin_username` | Reserved names | Azure rejects `admin`, `administrator` and others at create time |

## Known limitation

`admin_password` is written to state in plaintext. azurerm 4.x offers no
write-only variant of the argument, checked against the 4.81 provider schema, so
this cannot be fixed in the module. Anyone who can read state holds the
credential. See `docs/risk-and-limitations.md`.
