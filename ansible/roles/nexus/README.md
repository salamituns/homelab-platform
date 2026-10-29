# Role: `nexus`

Nexus Repository Community Edition on `nexus` (VMID 124, `192.168.1.87`), with the Docker registry
`registry.home.arpa`, per [ADR 0011](../../../docs/adr/0011-ci-platform-rebuild.md).

## What it does

1. **Disk (`tasks/disk.yml`)**: formats the empty data disk `/dev/sdb` (never an existing filesystem) and mounts it by
   UUID on `/var/lib/nexus`. Database, blobs and logs live there.
2. **Install (`tasks/install.yml`)**: pinned archive (`nexus_version`, SHA-256 `nexus_sha256`, checked 2026-10-29), unpacked
   root-owned to `/opt/nexus-<version>`, symlink `/opt/nexus`. The archive bundles its JDK.
3. **Service (`tasks/service.yml`)**: heap and data paths in `nexus.vmoptions`; `nexus.properties` binds 127.0.0.1:8081 and
   keeps API scripts off; sandboxed `nexus.service` (only `/var/lib/nexus` writable).
4. **Bootstrap (`tasks/bootstrap.yml`)**, through the REST API on localhost:
   - replaces the first-start admin password; ours is in `/root/nexus-admin-password` (0600)
   - anonymous access off; Docker bearer-token realm on
   - Docker hosted repos from `nexus_docker_repos`, each on a localhost connector port, tags immutable (`allow_once`)
   - service users from `nexus_service_users`, one role each: `ci-push` (push to `belleshop`), `k8s-pull` (pull only);
     passwords generated on the host in `/etc/nexus/secrets/<user>` (0600)

The `caddy` role then serves `nexus.home.arpa` (UI/API) and `registry.home.arpa` (Docker) on 443, and fetches its root CA
to `ansible/files/ca/nexus-caddy-root.crt` for the Mac, the CI agent and the k8s nodes.

## Notes

- If the admin password is changed in the UI, update `/root/nexus-admin-password` too, or later runs cannot log in.
- Upgrade: bump `nexus_version` + `nexus_sha256`, run the playbook; the old `/opt/nexus-<old>` stays for rollback.
- Not yet: cleanup policies, a database export task for consistent backups.
