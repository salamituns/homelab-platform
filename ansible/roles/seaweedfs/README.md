# Role: seaweedfs

Single-node SeaweedFS (master + volume + filer + S3 gateway in one `weed server` process) as the
S3 store for Terraform state. ADR 0007, runbook `docs/runbooks/terraform-state.md`.

- Binary: pinned release tarball, SHA-256 verified, unpacked to `/opt/seaweedfs/<version>/weed`,
  linked from `/usr/local/bin/weed`.
- Listens on 127.0.0.1 only. Pair with `roles/caddy` for TLS on 443.
- `/etc/seaweedfs/s3.json` (0640 root:seaweedfs) holds the S3 identities. Keys come from the
  controller's `~/.aws/credentials`; the template task runs with `no_log` and no diff.
- Buckets are created and versioned with `weed shell` on the host, so no S3 identity needs `Admin`.

## The identity's `actions`

Terraform's S3 backend does, for `key = proxmox/terraform.tfstate`:

| Call | When |
|---|---|
| `ListObjectsV2` on the bucket | `init`, listing workspaces |
| `GetObject` / `PutObject` on the state | every plan and apply |
| `PutObject` with `If-None-Match: *` on `<key>.tflock` | taking the lock |
| `GetObject` / `DeleteObject` on `<key>.tflock` | reading lock info, releasing the lock |

SeaweedFS actions are coarse (`Read`, `Write`, `List`, `Tagging`, `Admin`, ...; `Write` covers put and
delete). Scope each with `:<bucket>`, as in `Read:tfstate`.

## Object Lock

`Write` in SeaweedFS also allows suspending versioning, deleting a specific version and setting lifecycle
rules, so versioning alone does not protect history from a leaked key. Buckets with `object_lock: true`
get Object Lock (via `weed shell`, irreversible) and, with `-e seaweedfs_set_retention=true`, a default
retention set by a key that exists only for that run (`tasks/retention.yml`).
