# Role: `gitea`

Deploys and hardens the rebuilt Gitea server on `gitea` (`192.168.1.97`, VMID 122) per [ADR 0005](../../../docs/adr/0005-gitea-rebuild.md) and the [CVE-2026-60004 postmortem](../../../docs/postmortems/2026-10-25-gitea-rce-cve-2026-60004.md).

## What It Does

1. **Install (`tasks/install.yml`):**
   - Installs `git`, creates system user/group `git` (`/var/lib/gitea`), and creates `/var/lib/gitea/{custom,data,log}` (`git:git 0750`) and `/etc/gitea`, `/etc/gitea/secrets` (`root:git 0750`).
   - Downloads the pinned `gitea` binary (`gitea_version`) to `/usr/local/bin/gitea` with SHA-256 verification (`gitea_sha256`).
2. **Configuration & Service Hardening (`tasks/config.yml`):**
   - Generates `SECRET_KEY`, `INTERNAL_TOKEN`, `JWT_SECRET`, and `LFS_JWT_SECRET` on the host once into `/etc/gitea/secrets/*` (`root:git 0640`) using `gitea generate secret` with `no_log: true`.
   - Templates `/etc/gitea/app.ini` (`root:git 0640`) referencing those secret files via `*_URI = file:...` so `app.ini` contains no secrets and is idempotently managed.
   - Binds Gitea HTTP to `127.0.0.1:3000`, disables SSH, self-registration, Actions, LFS server, and mailer, enables `REQUIRE_SIGNIN_VIEW` and `OFFLINE_MODE`, and uses SQLite (`WAL` mode).
   - Runs `gitea.service` under systemd sandboxing (`ProtectSystem=strict`, `ReadWritePaths=/var/lib/gitea`, `NoNewPrivileges=true`, `PrivateTmp=true`, empty `CapabilityBoundingSet=`), keeping `/etc/gitea` read-only to the `git` process.
   - Waits for `http://127.0.0.1:3000/api/healthz` to return `200`.
3. **Admin Bootstrap (`tasks/admin.yml`):**
   - On first run (when `gitea admin user list --admin` returns no admin users), creates `gitea_admin_user` with a random 24-character password and `--must-change-password`, saving the output to `/root/gitea-initial-admin-password` (`0600`) on the host with `no_log: true`.
4. **Caddy TLS Proxy (`tasks/caddy.yml`):**
   - Installs Caddy from the official Cloudsmith apt repository with a signed keyring.
   - Terminates TLS for `gitea.home.arpa` (and `gitea-new.home.arpa` until cutover) using `tls internal` and proxies to `127.0.0.1:3000`.
   - Fetches Caddy's local root CA certificate (`/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt`) to `ansible/files/ca/gitea-caddy-root.crt` on the controller.
5. **Firewall (`tasks/firewall.yml`):**
   - Allows `443/tcp` in UFW from the five named lab clients (`master`, `workernode1`, `workernode2`, `gateway`, `mac`). Port `3000` is never opened.
6. **Backup (`tasks/backup.yml`):**
   - Configures `gitea-backup.timer` (daily systemd timer) to run `gitea dump` as `git` into `/var/backups/gitea`, keeping the 7 most recent archives.

## Variables (`defaults/main.yml`)

| Variable | Default | Purpose |
|---|---|---|
| `gitea_version` | `"1.27.3"` | Pinned Gitea release version |
| `gitea_sha256` | `"4da93c2c...12d971"` | SHA-256 checksum of `gitea-<version>-linux-amd64` |
| `gitea_download_url` | `https://dl.gitea.com/...` | Binary download URL |
| `gitea_domain` | `gitea.home.arpa` | Canonical Gitea hostname |
| `gitea_extra_names` | `["gitea-new.home.arpa"]` | Extra TLS Subject Alternative Names before cutover |
| `gitea_http_port` | `3000` | Loopback HTTP port behind Caddy |
| `gitea_admin_user` | `tunsgit` | Initial admin username |
| `gitea_admin_email` | `admin@home.arpa` | Initial admin email |
| `gitea_https_clients` | 5 `{name, ip}` entries | Clients allowed to reach `443/tcp` through UFW |
| `gitea_backup_dir` | `/var/backups/gitea` | Local directory for daily `gitea dump` archives |
| `gitea_backup_keep` | `7` | Number of daily dump archives to retain |
| `gitea_ca_fetch_dest` | `.../files/ca/gitea-caddy-root.crt` | Controller destination for Caddy's local root CA |

## First-Run Operator Steps

1. Run the playbook against the new VM:
   ```sh
   cd ~/homelab-platform/ansible
   ansible-playbook playbooks/gitea.yml --limit gitea
   ```
2. Trust the fetched Caddy root CA (`ansible/files/ca/gitea-caddy-root.crt`) on your Mac and in Argo CD.
3. Read the one-time initial admin password on the Gitea host:
   ```sh
   ssh gitea 'sudo cat /root/gitea-initial-admin-password'
   ```
4. Log in at `https://gitea-new.home.arpa/` (or `https://gitea.home.arpa/` after DNS cutover) as `tunsgit`, complete the forced password change, and enable **2FA (TOTP)** in user settings.
5. Delete the initial password file from the host:
   ```sh
   ssh gitea 'sudo shred -u /root/gitea-initial-admin-password'
   ```

## How to Upgrade Gitea

1. Update `gitea_version` and `gitea_sha256` in `ansible/roles/gitea/defaults/main.yml` with the new release version and verified `linux-amd64` SHA-256 digest.
2. Run:
   ```sh
   cd ~/homelab-platform/ansible
   ansible-playbook playbooks/gitea.yml --limit gitea --diff
   ```
   `get_url` verifies the checksum, replaces `/usr/local/bin/gitea`, and triggers `Restart gitea` (which runs database migrations automatically).
