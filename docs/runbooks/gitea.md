# Runbook: operate the Gitea server (`gitea.home.arpa`)

Design: [ADR 0005](../adr/0005-gitea-rebuild.md). Role: `ansible/roles/gitea/`. Playbook: `ansible/playbooks/gitea.yml`.

## 1. Overview

| Item | Value |
|---|---|
| Host | `gitea` (VMID 122, `192.168.1.97`, `https://gitea.home.arpa/`) |
| Listeners | Caddy on `443/tcp` (`tls internal`), Gitea on `127.0.0.1:3000`, OpenSSH on `22/tcp` (Gitea SSH disabled) |
| Firewall (UFW) | Default deny incoming; `22/tcp` open; `443/tcp` allowed only from `master` (`.90`), `workernode1` (`.89`), `workernode2` (`.84`), `gateway` (`.96`), and Mac (`.121`) |
| Data & config | `/var/lib/gitea` (SQLite DB at `data/gitea.db`, repos at `data/gitea-repositories`); `/etc/gitea/app.ini` and `/etc/gitea/secrets/*` (`root:git 0640`, read-only to `gitea.service`) |
| Backups | `/var/backups/gitea` (`gitea-dump-*.zip`), run daily as `git` by `gitea-backup.timer` (`gitea-backup.service`), keeping the 7 newest archives |

Check health from the Mac:

```sh
curl -q --cacert ansible/files/ca/gitea-caddy-root.crt -sS https://gitea.home.arpa/api/healthz
curl -q --cacert ansible/files/ca/gitea-caddy-root.crt -sS https://gitea.home.arpa/api/v1/version
ssh tunsadmin@192.168.1.97 'systemctl is-active gitea caddy gitea-backup.timer'
```

## 2. Upgrade Gitea

1. Fetch the SHA-256 digest from the official `.sha256` file for the target release:
   ```sh
   VER=1.27.3
   curl -q -sSfL "https://dl.gitea.com/gitea/${VER}/gitea-${VER}-linux-amd64.sha256"
   ```
2. Update `gitea_version` and `gitea_sha256` in `ansible/roles/gitea/defaults/main.yml`.
3. Dry-run first, then apply, then verify the running version:
   ```sh
   cd ~/homelab-platform/ansible
   ansible-playbook playbooks/gitea.yml --limit gitea --check --diff
   ansible-playbook playbooks/gitea.yml --limit gitea
   curl -q --cacert files/ca/gitea-caddy-root.crt -sS https://gitea.home.arpa/api/v1/version
   ```

## 3. Trust the Caddy root CA on a new client

The public root CA certificate is fetched by the role to `ansible/files/ca/gitea-caddy-root.crt` (replaced by the lab CA in week 6).

### macOS (system keychain + per-host `git` config)

```sh
cd ~/homelab-platform
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  ansible/files/ca/gitea-caddy-root.crt

git config --global http."https://gitea.home.arpa/".sslCAInfo \
  "$HOME/homelab-platform/ansible/files/ca/gitea-caddy-root.crt"
```

### Argo CD (`argocd-tls-certs-cm` ConfigMap)

Declared in `k8s/platform/cluster-config/argocd-tls-certs-cm.yaml` (keyed by `gitea.home.arpa`).
Since 2026-10-27 the Argo CD app `cluster-config` applies it: change the file, commit and push (ADR 0008).
Break-glass, if Argo CD cannot reach Gitea because this very CA is wrong:

```sh
kubectl apply -f k8s/platform/cluster-config/argocd-tls-certs-cm.yaml
```

## 4. Rotate the Argo CD repository token

1. In Gitea (`https://gitea.home.arpa/user/settings/applications`), delete the old `argocd-readonly` token and create a new token with **`read:repository`** scope only.
2. Apply the Kubernetes Secret via stdin so the token never touches disk, shell history, or `ps` argv:
   ```sh
   read -rs -p "New argocd-readonly token: " ARGOCD_GITEA_TOKEN; echo
   printf '%s' "$ARGOCD_GITEA_TOKEN" |
     kubectl create secret generic gitea-belleshop-readonly \
       --namespace=argocd \
       --from-literal=type=git \
       --from-literal=url=https://gitea.home.arpa/tunsgit/BelleShop.git \
       --from-literal=username=tunsgit \
       --from-file=password=/dev/stdin \
       --dry-run=client -o yaml |
     kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml |
     kubectl apply -f -
   unset ARGOCD_GITEA_TOKEN
   ```
3. Verify Argo CD can fetch from Gitea:
   ```sh
   kubectl -n argocd get application belleshop
   kubectl -n argocd logs deploy/argocd-repo-server --tail=30
   ```

## 5. Restore from a `gitea dump` archive

> **Status: Untested until the Week 2 restore drill.**

Outline of the official Gitea restore procedure from `/var/backups/gitea/gitea-dump-<timestamp>.zip`:

```sh
ssh tunsadmin@192.168.1.97
sudo systemctl stop gitea

# Unpack the dump archive in a temporary directory owned by git
sudo -u git mkdir -p /var/lib/gitea/restore
sudo -u git unzip -q /var/backups/gitea/gitea-dump-<timestamp>.zip -d /var/lib/gitea/restore

# Restore into a FRESH database file: importing the SQL into the existing gitea.db fails
# ("table already exists") or mixes old and restored rows. Keep the current one for rollback.
sudo apt-get install -y sqlite3
sudo -u git mv /var/lib/gitea/data/gitea.db /var/lib/gitea/data/gitea.db.pre-restore
sudo -u git sh -c 'sqlite3 /var/lib/gitea/data/gitea.db < /var/lib/gitea/restore/gitea-db.sql'
sudo -u git rsync -a --delete /var/lib/gitea/restore/repos/ /var/lib/gitea/data/gitea-repositories/
sudo -u git rm -rf /var/lib/gitea/restore

# Regenerate git hooks from Gitea's own templates (never trust hooks from an archive: CVE-2026-60004)
sudo systemctl start gitea
sudo /usr/sbin/runuser -u git -- /usr/local/bin/gitea admin regenerate hooks \
  --work-path /var/lib/gitea --config /etc/gitea/app.ini
```
