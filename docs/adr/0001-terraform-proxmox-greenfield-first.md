# ADR 0001: Manage Proxmox VMs with Terraform, greenfield first

- Status: accepted
- Date: 2026-10-23

## Context
All 12 VMs on `tuns` (Proxmox 9.1) were built by hand. Nothing is reproducible, and there is
no record of how any VM is sized or configured.

## Decision
- Use Terraform with the `bpg/proxmox` provider, authenticating with a scoped API token
  (`terraform@pve`), not root.
- New VMs are created only through Terraform, cloned from cloud-init template 109.
- Existing VMs (100-111) stay unmanaged for now. They are brought in one at a time later,
  either via `terraform import` or by rebuilding them from code and cutting over.
- Ansible owns in-guest configuration; Terraform owns VM existence and sizing.

## Consequences
- A VM can be destroyed and rebuilt from git in minutes.
- Importing existing VMs is deferred work, and their drift from code is a known risk.
- State is local in week 1 (single operator); it moves to a MinIO S3 backend in week 2.
- Template 110 (`Template-Hardened`) carries a stale cloud-init IP (10.2.0.110/21) that is
  not on the LAN; it is not used until fixed.
