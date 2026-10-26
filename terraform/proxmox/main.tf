# Every Terraform-managed VM is one entry here. Adding a VM = adding a map entry + PR.
# Existing hand-built VMs (100-111) are NOT managed yet; see docs/adr/0001.
locals {
  vms = {
    sectools = {
      vm_id        = 120
      ipv4_address = "192.168.1.95"
      cores        = 2
      memory_mb    = 4096
      disk_gb      = 60
      tags         = ["devsecops"]
    }
    # Tailscale subnet router: remote access to 192.168.1.0/24. One job only, see docs/adr/0002.
    gateway = {
      vm_id        = 121
      ipv4_address = "192.168.1.96"
      cores        = 1
      memory_mb    = 1024
      disk_gb      = 40
      tags         = ["network", "tailscale"]
    }
    # Gitea, rebuilt after the 2026-10-25 incident (docs/adr/0005). Replaces UbuntuNew.
    gitea = {
      vm_id        = 122
      ipv4_address = "192.168.1.97"
      cores        = 2
      memory_mb    = 2048
      disk_gb      = 40
      tags         = ["git", "platform"]
    }
    # Proxmox Backup Server (docs/adr/0006). PBS 4 supports Debian 13 only, hence its own template.
    # The datastore disk has backup = false: backing the backup store up into itself is a loop.
    pbs = {
      vm_id        = 123
      template_id  = var.debian_template_id
      ipv4_address = "192.168.1.98"
      cores        = 2
      memory_mb    = 4096
      disk_gb      = 40
      data_disks   = [{ size_gb = 500, backup = false }]
      tags         = ["backup", "platform"]
    }
  }
}

module "vm" {
  source   = "./modules/vm"
  for_each = local.vms

  name            = each.key
  vm_id           = each.value.vm_id
  template_id     = try(each.value.template_id, var.template_id)
  data_disks      = try(each.value.data_disks, [])
  ipv4_address    = each.value.ipv4_address
  cores           = each.value.cores
  memory_mb       = each.value.memory_mb
  disk_gb         = each.value.disk_gb
  tags            = each.value.tags
  gateway         = var.gateway
  dns_servers     = var.dns_servers
  ssh_public_keys = var.ssh_public_keys
}
