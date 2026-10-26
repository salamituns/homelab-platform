# ADR 0006: VM backups with Proxmox Backup Server

- Status: Accepted (stage 1); stage 2 deferred
- Date: 2026-10-26

## Context

The 2026-10-26 baseline found that no VM had a working backup. The only active vzdump job wrote to
`backup-3tb`, which is a 16 GB LV and not a separate disk. It held one archive and failed every week
with a full disk; failure mails went nowhere. A read-only survey the same day found:

- One block device: a PERC H330 RAID 1 of two 4 TB HGST drives, same model, near-consecutive serials,
  ~80,000 power-on hours each (about 9 years). Healthy today (0 reallocated or pending sectors).
- No other storage: nothing on USB, no NAS; the admin Mac has 14 GB free.
- ~325 GB of live VM data; the thin pool is 11% used.
- 13 LVM-thin snapshots (`before-ansible-hardening`, ...). They live in the same pool, so they are not backups.

RAID 1 covers one disk failing. It does not cover a bad upgrade, a deleted VM, or a compromised guest:
those are mirrored to both disks at once. Two same-batch drives this old are also likely to fail
close together, often during the rebuild after the first one goes.

## Decision

| Question | Choice | Why |
|---|---|---|
| Tool | Proxmox Backup Server 4 | Incremental, deduplicated, verified backups; native to PVE; file-level restore |
| Where PBS runs | Its own VM `pbs` (VMID 123, `192.168.1.98`, Terraform) | A separate trust domain from the hypervisor (the AWS Backup "vault in another account" idea) |
| OS | Debian 13 from template 130 (`scripts/build-debian-template.sh`) | PBS 4 supports Debian 13 only; the image is pinned by SHA-512 in git |
| Datastore | 500 GB thin disk `scsi1`, `backup = false` | Room for dedup history; backing the store up into itself would be a loop |
| Who can delete | PBS only (prune, GC, verify jobs run on PBS); PVE's token has `DatastoreBackup` | A compromised hypervisor can add backups but not erase them |
| Scope | One daily job, `all` minus excludes (101 forensic, 123 PBS) | Opt-out: a new VM is backed up without anyone remembering to add it |
| Alerts | PVE and PBS notification system to Gmail SMTP (app password, never in git) | The old job failed silently for months |
| Proof | Restore drill: restore a VM to a new VMID and boot it | A backup nobody has restored is a hope, not a backup |

## Stage 2 (deferred by the owner, 2026-10-26): a second medium

Stage 1 does **not** protect against losing the array or the host: PBS sits on the same disks.
Options when the owner decides: a USB 3 disk on the server as a PBS sync target, or
client-side-encrypted sync to object storage (offsite). Until then baseline C1 stays open as
"partially fixed", and the risk is written here on purpose.

## Consequences

- One more VM to patch. It gets the same baseline role as the rest.
- Template 130 joins template 109 under Terraform's clone permission (`TerraformClone` on `/vms/130`).
- The old jobs are retired. `backup-3tb` and its March UbuntuNew archive stay until the forensic
  retention ends (2026-11-25).
- The thin snapshots are reviewed for deletion after the first successful restore drill.

## Implementation notes (2026-10-26)

- Built: template 130 (`scripts/build-debian-template.sh`), VM `pbs` (Terraform), `playbooks/pbs.yml`,
  `scripts/connect-pve-to-pbs.sh`, `playbooks/proxmox-backup.yml` (`daily-all` at 01:30, Gmail matcher),
  `scripts/restore-drill.sh`. Old jobs `weekly-critical` and `monthly-important` deleted.
- First run: 15 VMs, 603 GiB logical, 113 GiB stored. Restore drill of `gitea`: PASS in 370 s.
- Lessons: a PBS token's rights are its own ACL **intersected** with its user's (grant both);
  `pvesm add` test-connects an enabled PBS storage and deletes any `.pw` file when no password is given
  (add disabled, write the secret, then enable); a DNS record in git is not live until
  `playbooks/dns.yml` runs on `gateway`.
- Open: stage 2 (second medium); client-side encryption (decide before stage 2, since a cloud copy needs it).
