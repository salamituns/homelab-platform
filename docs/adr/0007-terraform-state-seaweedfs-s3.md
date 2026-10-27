# ADR 0007: Terraform state in an S3 bucket on SeaweedFS

- Status: Accepted
- Date: 2026-10-27

## Context

Terraform state for `terraform/proxmox` was a local file on the admin Mac: no lock, no history,
and lost with the laptop. It is also a secret: it holds cloud-init passwords for three VMs.
The roadmap planned MinIO on `sectools`. By 2026 the MinIO Community Edition no longer ships
binaries (2025), went into maintenance mode (2025-12) and was archived (2026), so it gets no fixes.

## Decision

| Question | Choice | Why |
|---|---|---|
| S3 server | SeaweedFS 4.48 (Apache 2.0, one Go binary, pinned by SHA-256) | Has bucket versioning and `If-None-Match` writes, the two features a state backend needs |
| Rejected | Garage (no versioning), RustFS (young, conditional-write fixes still landing), third-party MinIO builds (one outside maintainer) | |
| Where | `sectools` (VMID 120), owner's choice; the VM was nearly empty | No new VM to patch |
| Exposure | Every SeaweedFS port on 127.0.0.1; Caddy `tls internal` on 443 as `s3.home.arpa`; ufw allows only `lab_admin_clients` | State crosses the LAN encrypted, and only admin machines can reach it |
| Locking | Terraform's S3 lockfile (`use_lockfile`, Terraform 1.11+) | No DynamoDB-style lock table to run |
| History | Bucket versioning + **Object Lock, 30-day GOVERNANCE default retention** (both set on the host / by a short-lived key) | A corrupt or wrong write can be rolled back, and no standing key can erase that history |
| Who can do what | Terraform's S3 key: `List`, `Read`, `Write` on `tfstate` only; buckets are made, versioned and locked on the host, not over S3 | A leaked key cannot delete the bucket, turn versioning off, or delete a version younger than 30 days |
| Keys | `~/.aws/credentials` profile `homelab-tfstate` on the Mac (0600); Ansible reads it to write `/etc/seaweedfs/s3.json` | Same place the AWS tooling looks; not in git, not in the repo's `.envrc` |
| Backups | `sectools` is in the nightly PBS job (ADR 0006) | A second copy of the state outside the bucket |

## Consequences

- `terraform` must be 1.11+ on the Mac (it was 1.9.8).
- The cloud equivalent is S3 with versioning plus a bucket policy scoped to one IAM role. The
  difference here: one node, no replication, and the store's disk is the same RAID 1 as everything else.
- Terraform cannot plan while `sectools` is down. Break-glass: copy the latest object version to a
  local file and run with `-backend=false` / a local override (runbook).
- The Caddy pattern now exists twice (`roles/gitea/tasks/caddy.yml`, `roles/caddy`). Backlog: move gitea onto `roles/caddy`.

## Implementation notes (2026-10-27)

- **Test before trusting.** With versioning alone, the `terraform` key (only `Write:tfstate`) could
  suspend versioning, permanently delete an old version, and set a lifecycle rule expiring old versions.
  SeaweedFS 4.48 gates `PutBucketVersioning`, `DeleteObject?versionId` and `PutBucketLifecycle` on
  plain `Write`; no finer action exists. Fix: Object Lock with a default retention.
- After Object Lock, the same key gets: version delete `AccessDenied`, suspend versioning `InvalidBucketState`,
  shorten retention `AccessDenied`, `--bypass-governance-retention` `AccessDenied`. Lifecycle deletes call
  `enforceObjectLockProtections` and never bypass a lock (source, `s3api_internal_lifecycle.go`).
- Default retention needs `PutBucketObjectLockConfiguration`. No standing key has it: the playbook generates
  a key in memory, adds it to `s3.json` for one run, uses it from the controller, and removes it in an `always:` block.
- Terraform's lock still works on a locked bucket: unlock writes a delete marker, and a later `If-None-Match: *`
  put over the marker succeeds; a second concurrent put returns 412. Lock test: the second `plan` failed with
  "Error acquiring the state lock" (412) and named the holder.
- Migration: `init -migrate-state -force-copy`; plan showed no changes. The first S3 snapshot starts at serial 1
  with a new lineage (same 4 resources).
- Side fixes: `playbooks/dns.yml` split into server and client plays (an unreachable client before `gateway`
  ended the run, so `s3.home.arpa` never went live); Homebrew `awscli` 2.23 was broken (`No module named
  'cryptography'`), upgraded to 2.38; Terraform 1.9.8 -> 1.17.0.
- Cost of the lock: every state and `.tflock` version stays at least 30 days. They are a few KB each.
