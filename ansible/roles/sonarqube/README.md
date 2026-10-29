# Role: `sonarqube`

Deploys and hardens SonarQube Community Build on `sonarqube` (`192.168.1.86`, VMID 125) per [ADR 0011](../../../docs/adr/0011-ci-platform-rebuild.md).

## What It Does

1. **Kernel Limits (`tasks/sysctl.yml`):**
   - Configures `vm.max_map_count=524288` and `fs.file-max=131072` in `/etc/sysctl.d/99-sonarqube.conf`. SonarQube's embedded Elasticsearch runs bootstrap checks at startup and refuses to start without them.
2. **Install (`tasks/install.yml`):**
   - Installs `openjdk-21-jre-headless` and `unzip` from Ubuntu apt.
   - Creates system user/group `sonar` (`/var/lib/sonarqube`, `/usr/sbin/nologin`), data/temp/log directories (`/var/lib/sonarqube/{data,temp}`, `/var/log/sonarqube`, `sonar:sonar 0750`), and `/etc/sonarqube`, `/etc/sonarqube/secrets` (`root:sonar 0750`).
   - Downloads the pinned SonarQube Community Build zip (`26.10.0.133078`, checked `2026-10-29`) from `binaries.sonarsource.com` with SHA-256 verification, extracts it to `/opt/sonarqube-26.10.0.133078`, and manages the `/opt/sonarqube` symlink.
3. **Database (`tasks/database.yml`):**
   - Installs PostgreSQL 16 from Ubuntu apt and binds it to `127.0.0.1` only (`listen_addresses = '127.0.0.1'`).
   - Generates a random database password on the host once into `/etc/sonarqube/secrets/db_password` (`root:sonar 0640`, `no_log: true`).
   - Creates PostgreSQL role `sonar` and UTF-8 database `sonarqube` owned by `sonar`.
4. **Configuration & Service Hardening (`tasks/config.yml`):**
   - Renders `/etc/sonarqube/sonar.properties` (`root:sonar 0640`, `no_log: true`, `diff: false`) and links `/opt/sonarqube-<version>/conf/sonar.properties` to it.
   - Binds SonarQube web server to `127.0.0.1:9000`, sets `sonar.forceAuthentication=true`, places data/temp under `/var/lib/sonarqube` and logs under `/var/log/sonarqube`, and sizes JVM heaps for a 4 GB VM (Web `512m`, Compute Engine `1024m`, Elasticsearch `1024m` + `512m` direct memory).
   - Runs `sonarqube.service` as `sonar` with `LimitNOFILE=131072`, `LimitNPROC=8192`, and systemd sandboxing (`ProtectSystem=strict`, `ReadWritePaths=/var/lib/sonarqube /var/log/sonarqube`, `NoNewPrivileges=true`, `PrivateTmp=true`, empty `CapabilityBoundingSet=`).
   - Waits for `http://127.0.0.1:9000/api/system/status` to report `"status":"UP"`.
5. **Admin Bootstrap (`tasks/admin.yml`):**
   - Checks `/api/authentication/validate` with the built-in `admin/admin` login; if still valid, rotates the `admin` password via `POST /api/users/change_password` to a random password saved on the host at `/root/sonarqube-initial-admin-password` (`0600`) with `no_log: true`.
6. **Backup (`tasks/backup.yml`):**
   - Configures `sonarqube-backup.timer` (daily systemd timer) to run `pg_dump --format=custom` as `sonar` into `/var/backups/sonarqube`, keeping the 7 most recent dumps.
7. **TLS & Firewall (Playbook + `host_vars/sonarqube.yml`):**
   - Paired with `roles/caddy` (`sonarqube.home.arpa` and alias `sonar.home.arpa` -> `127.0.0.1:9000`) and `roles/firewall` (`443/tcp` allowed from `lab_admin_clients`, `jenkins` `192.168.1.88`, and `ci-agent` `192.168.1.93`).

## Variables (`defaults/main.yml`)

| Variable | Default | Purpose |
|---|---|---|
| `sonarqube_version` | `"26.10.0.133078"` | Pinned SonarQube Community Build release (checked 2026-10-29) |
| `sonarqube_sha256` | `"a2371645...db62c1"` | SHA-256 from `binaries.sonarsource.com/.../sonarqube-26.10.0.133078.zip.sha256` |
| `sonarqube_download_url` | `https://binaries.sonarsource.com/...` | Official Community Build zip URL |
| `sonarqube_java_package` | `openjdk-21-jre-headless` | Ubuntu apt Java 21 runtime required by SonarQube 26.x |
| `sonarqube_postgresql_version` | `"16"` | Ubuntu 24.04 PostgreSQL major version |
| `sonarqube_db_name` | `sonarqube` | Local PostgreSQL database name |
| `sonarqube_db_user` | `sonar` | Local PostgreSQL role name |
| `sonarqube_db_password_file` | `/etc/sonarqube/secrets/db_password` | Host-generated DB password file (`root:sonar 0640`) |
| `sonarqube_web_host` | `127.0.0.1` | Loopback address bound by SonarQube web process |
| `sonarqube_web_port` | `9000` | Loopback HTTP port behind Caddy |
| `sonarqube_data_dir` | `/var/lib/sonarqube/data` | Persistent Elasticsearch index directory |
| `sonarqube_temp_dir` | `/var/lib/sonarqube/temp` | Temporary working directory |
| `sonarqube_log_dir` | `/var/log/sonarqube` | Log directory (`sonar.log`, `es.log`, `web.log`, `ce.log`) |
| `sonarqube_web_java_opts` | `-Xmx512m -Xms128m ...` | Web JVM heap options (4 GB VM budget) |
| `sonarqube_ce_java_opts` | `-Xmx1024m -Xms128m ...` | Compute Engine JVM heap options (4 GB VM budget) |
| `sonarqube_search_java_opts` | `-Xmx1024m -Xms1024m ...` | Elasticsearch JVM heap options (4 GB VM budget) |
| `sonarqube_initial_admin_password_file` | `/root/sonarqube-initial-admin-password` | One-time rotated admin password file (`0600`) |
| `sonarqube_backup_dir` | `/var/backups/sonarqube` | Local directory for daily `pg_dump` archives |
| `sonarqube_backup_keep` | `7` | Number of daily PostgreSQL dump files to retain |

## First-Run Operator Steps

1. Run the playbook once the `sonarqube` VM (`192.168.1.86`) is provisioned:
   ```sh
   cd ~/homelab-platform/ansible
   ansible-playbook playbooks/sonarqube.yml --limit sonarqube
   ```
2. Trust the fetched Caddy root CA (`ansible/files/ca/sonarqube-caddy-root.crt`) on the Mac.
   (`jenkins` and `ci-agent` get it automatically from the `lab_ca_trust` role.)
3. Read the initial `admin` password generated on the host:
   ```sh
   ssh sonarqube 'sudo cat /root/sonarqube-initial-admin-password'
   ```
4. Log in at `https://sonarqube.home.arpa/` as `admin`, rotate the password to your password manager if desired, and shred the bootstrap file:
   ```sh
   ssh sonarqube 'sudo shred -u /root/sonarqube-initial-admin-password'
   ```

## How to Upgrade SonarQube

1. Update `sonarqube_version` and `sonarqube_sha256` in `ansible/roles/sonarqube/defaults/main.yml` from `https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-<version>.zip.sha256`.
2. Run:
   ```sh
   cd ~/homelab-platform/ansible
   ansible-playbook playbooks/sonarqube.yml --limit sonarqube --diff
   ```
3. If `/api/system/status` reports `DB_MIGRATION_NEEDED`, trigger `/api/system/migrate_db` (`POST`) or visit `https://sonarqube.home.arpa/setup`.
