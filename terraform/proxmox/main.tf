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
  }
}

module "vm" {
  source   = "./modules/vm"
  for_each = local.vms

  name            = each.key
  vm_id           = each.value.vm_id
  template_id     = var.template_id
  ipv4_address    = each.value.ipv4_address
  cores           = each.value.cores
  memory_mb       = each.value.memory_mb
  disk_gb         = each.value.disk_gb
  tags            = each.value.tags
  gateway         = var.gateway
  dns_servers     = var.dns_servers
  ssh_public_keys = var.ssh_public_keys
}
