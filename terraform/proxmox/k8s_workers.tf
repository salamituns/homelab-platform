# The two k8s workers were built by hand from the Ubuntu ISO (2025) and adopted by import (ADR 0010),
# so their sizing lives in git. Not the vm module: its clone block on an existing VM would plan a replace.
# This resource describes the VMs as they are (no cloud-init, NIC firewall off, ISO still in ide2).
locals {
  k8s_workers = {
    WorkerNode1 = { vm_id = 107, mac = "BC:24:11:85:62:B1", disk_gb = 40 }
    WorkerNode2 = { vm_id = 102, mac = "BC:24:11:E5:C7:C3", disk_gb = 40 }
  }
}

import {
  for_each = local.k8s_workers
  to       = proxmox_virtual_environment_vm.k8s_worker[each.key]
  id       = "tuns/${each.value.vm_id}"
}

resource "proxmox_virtual_environment_vm" "k8s_worker" {
  for_each = local.k8s_workers

  name          = each.key
  node_name     = "tuns"
  vm_id         = each.value.vm_id
  pool_id       = "terraform"
  on_boot       = true
  boot_order    = ["scsi0", "ide2", "net0"]
  scsi_hardware = "virtio-scsi-single"

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

  network_device {
    bridge      = "vmbr0"
    mac_address = each.value.mac # the MAC is the node's identity on the LAN (static IP, MetalLB L2)
    firewall    = false
  }

  operating_system {
    type = "l26"
  }

  startup {
    order    = 3
    up_delay = 15
  }

  lifecycle {
    # A worker holds local-path PVs: a plan that destroys or replaces one must fail, not run.
    prevent_destroy = true
  }
}
