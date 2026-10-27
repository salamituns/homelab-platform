# ADR 0010: Adopt the k8s workers into Terraform by import, then grow their disks

- Status: Accepted
- Date: 2026-10-27

## Context

The worker disks were 70% (WorkerNode1) and 83% (WorkerNode2) full; 40 GB each, of which ~8-10 GB is
container images and ~4 GB is the systemd journal. Both VMs were built by hand from the Ubuntu ISO, so
their size was not in git (ADR 0001 deferred importing hand-built VMs). Longhorn was the alternative,
but its replicas need free disk, which these workers do not have.

## Decision

| Question | Choice | Why |
|---|---|---|
| Ownership | `terraform/proxmox/k8s_workers.tf`, `import` blocks, VMIDs 107 and 102 | The import is part of a reviewed plan, not a command that writes state directly |
| Resource | Its own `proxmox_virtual_environment_vm`, not `modules/vm` | The module's `clone {}` block on an existing VM plans a destroy and re-create |
| First apply | Config written to match the VMs exactly: plan `2 to import, 0 to change` | Take ownership first, change things second, so each plan shows one kind of change |
| Permission | VMs 102 and 107 added to pool `terraform` (the token's only scope) | The token now can delete them, so `prevent_destroy = true` makes such a plan fail |
| Reboots | `reboot_after_update = false` | An apply must never reboot a k8s node without a drain |
| Size | 40 -> 80 GB each; guest grown online by `ansible/playbooks/grow-root-disk.yml` | Thin pool is 15% used; thin LVs only use what the guest writes |
| Hardening in the same change | ISO ejected (`cdrom file_id = "none"`), `boot_order = ["scsi0"]` | Found by the security review of the import commit: a failed disk boot fell back to the installer or PXE |

## Not now

- NIC `firewall = false` stays (the vm module uses `true`). The Proxmox firewall is off cluster-wide
  (`enable: 0`), so `true` filters nothing, and changing it re-plugs the NIC: a link drop on a k8s node.
  It is turned on, with rules, for every VM in Week 6.
- MasterNode (108) is not imported; same steps when it needs it.
- The journal (~4 GB per worker) should be capped by the baseline role (`SystemMaxUse`).

## Consequences

- Disk size of the workers is changed in git; Proxmox cannot shrink, so a smaller number fails the apply.
- The `before-ansible-hardening` snapshots predate the resize; rolling back to them restores a 40 GB disk
  and Terraform would show drift.
- The `import` blocks stay: with a lost state, an apply re-adopts the VMs instead of failing on "already exists".
