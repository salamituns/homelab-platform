# The k8s VMs were built by hand from the Ubuntu ISO (2025) and adopted by import (ADR 0010),
# so their sizing lives in git. Not the vm module: its clone block on an existing VM would plan a replace.
# Imported exactly as they were (0 to change), then hardened in the open: ISO ejected, disk-only boot.
locals {
  # startup: the control plane boots first, the workers join it after
  k8s_nodes = {
    MasterNode  = { vm_id = 108, mac = "BC:24:11:67:AC:73", disk_gb = 40, boot_order = 2, up_delay = 30 }
    WorkerNode1 = { vm_id = 107, mac = "BC:24:11:85:62:B1", disk_gb = 80, boot_order = 3, up_delay = 15 }
    WorkerNode2 = { vm_id = 102, mac = "BC:24:11:E5:C7:C3", disk_gb = 80, boot_order = 3, up_delay = 15 }
  }
}

# Renamed from k8s_worker when the master joined: without these, the rename plans destroy + create.
moved {
  from = proxmox_virtual_environment_vm.k8s_worker["WorkerNode1"]
  to   = proxmox_virtual_environment_vm.k8s_node["WorkerNode1"]
}
moved {
  from = proxmox_virtual_environment_vm.k8s_worker["WorkerNode2"]
  to   = proxmox_virtual_environment_vm.k8s_node["WorkerNode2"]
}

# Kept after the import: with a lost state, `terraform apply` re-adopts the VMs instead of failing.
import {
  for_each = local.k8s_nodes
  to       = proxmox_virtual_environment_vm.k8s_node[each.key]
  id       = "tuns/${each.value.vm_id}"
}

resource "proxmox_virtual_environment_vm" "k8s_node" {
  for_each = local.k8s_nodes

  name          = each.key
  node_name     = "tuns"
  vm_id         = each.value.vm_id
  pool_id       = "terraform"
  on_boot       = true
  boot_order    = ["scsi0"] # disk only: no fallback to the installer ISO or to PXE on the LAN
  scsi_hardware = "virtio-scsi-single"
  # Never reboot a k8s node from an apply: changes that need one wait for a drained, planned reboot
  reboot_after_update = false

  agent {
    enabled = true
  }

  cpu {
    cores = 2
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 4096
  }

  # Grow only: Proxmox cannot shrink a disk, so a smaller number here fails the apply.
  # The guest's partition and filesystem are grown afterwards (ansible/playbooks/grow-root-disk.yml).
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = each.value.disk_gb
    iothread     = true
    discard      = "ignore"
    file_format  = "raw"
  }

  # Installer ISO ejected; the empty drive stays so the VM's hardware does not change
  cdrom {
    interface = "ide2"
    file_id   = "none"
  }

  # firewall = false like before the import. The Proxmox firewall is off cluster-wide, so true would filter
  # nothing and re-plugging the NIC drops a k8s node's link. Turned on with rules for all VMs in Week 6.
  network_device {
    bridge      = "vmbr0"
    mac_address = each.value.mac # the MAC is the node's identity on the LAN (static IP, MetalLB L2)
    firewall    = false
  }

  operating_system {
    type = "l26"
  }

  startup {
    order    = each.value.boot_order
    up_delay = each.value.up_delay
  }

  lifecycle {
    # The master holds etcd, a worker holds local-path PVs: a plan that destroys or replaces one must fail.
    prevent_destroy = true
  }
}
