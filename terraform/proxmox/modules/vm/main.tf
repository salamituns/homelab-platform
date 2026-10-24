terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.117"
    }
  }
}

# One VM cloned from a cloud-init template. Everything that differs per VM is a variable.
resource "proxmox_virtual_environment_vm" "this" {
  name        = var.name
  description = "Managed by Terraform (homelab-platform). Do not edit in the Proxmox UI."
  node_name   = var.node_name
  vm_id       = var.vm_id
  pool_id     = var.pool_id
  tags        = sort(concat(["terraform"], var.tags))
  on_boot     = true

  clone {
    vm_id = var.template_id
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = var.cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.memory_mb
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.disk_gb
    iothread     = true
    discard      = "on"
  }

  network_device {
    bridge   = var.bridge
    firewall = true
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = var.datastore_id

    ip_config {
      ipv4 {
        address = "${var.ipv4_address}/${var.ipv4_prefix}"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      username = var.ci_user
      keys     = var.ssh_public_keys
    }
  }
}
