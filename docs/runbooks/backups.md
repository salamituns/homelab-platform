# Runbook: VM Backups with Proxmox Backup Server (`pbs.home.arpa`)

Host: `pbs` (`192.168.1.98`, `https://pbs.home.arpa:8007/`, Debian 13 `trixie`).
Role: `ansible/roles/pbs/`. Playbook: `ansible/playbooks/pbs.yml`.

## 1. Architecture

`pbs` is a dedicated Debian 13 VM with a 500 GB datastore disk (`/dev/sdb` mounted at `/srv/pbs-store`, datastore `store1`).
The Proxmox hypervisor (`tuns`) authenticates to `pbs` with a scoped API token (`pve@pbs!tuns`) granted **`DatastoreBackup` only** on `/datastore/store1`.
Because `DatastoreBackup` allows writing new backups and reading own backups but **cannot delete, prune, or run garbage collection**, a compromised hypervisor (or leaked PVE token) cannot wipe existing backups.
All retention pruning (`7` daily, `4` weekly, `3` monthly), daily garbage collection, and weekly chunk verification (`outdated-after: 30` days) are scheduled on `pbs` itself.
UFW on `pbs` allows `8007/tcp` only from `tuns` (`192.168.1.181`), the admin Mac (`192.168.1.121`), and `gateway` (`192.168.1.96`).

## 2. First-time setup (human)

### Step 1: Run the Ansible playbook against `pbs`

```sh
cd ~/homelab-platform/ansible
ansible-playbook playbooks/pbs.yml --limit pbs --check --diff
ansible-playbook playbooks/pbs.yml --limit pbs
```

### Step 2: Set `root@pam` password and enable TOTP on `pbs`

1. Set the Linux `root` password on `pbs` (used only by `root@pam` in the PBS web UI; root SSH remains disabled by `baseline`):
   ```sh
   ssh pbs 'sudo passwd root'
   ```
2. Open `https://pbs.home.arpa:8007/`, log in as `root@pam`, go to **Configuration** -> **Access Control** -> **Two Factor**, and add a **TOTP** factor plus offline **Recovery Keys**.

### Step 3: Create `pve@pbs` and least-privilege token `pve@pbs!tuns` on `pbs`

Run on `pbs` as `root`:

```sh
ssh pbs
sudo -i

# Create the pve@pbs user (no password needed; only its API token is used)
proxmox-backup-manager user create pve@pbs --comment "Proxmox VE hypervisor (tuns)"

# Generate the API token and write the secret directly to a 0600 file (never echoed)
umask 0077
proxmox-backup-manager user generate-token pve@pbs tuns \
  --comment "Append-only backup token for tuns" \
  --output-format json \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["value"])' > /root/pbs-tuns-token.secret

# Grant DatastoreBackup ONLY on /datastore/store1 (tokens do not inherit user permissions)
proxmox-backup-manager acl update /datastore/store1 DatastoreBackup --auth-id 'pve@pbs!tuns'

# Read the PBS TLS certificate SHA-256 fingerprint for pvesm on tuns
proxmox-backup-manager cert info | grep Fingerprint
```

> **Ownership note:** With `DatastoreBackup`, `pve@pbs!tuns` can only append to backup groups owned by `pve@pbs!tuns`. Do not run test backups as `root@pam` first, or subsequent runs as `pve@pbs!tuns` will fail the owner check (`proxmox-backup-manager datastore change-owner` fixes ownership if needed).

### Step 4: Register `pbs-store1` on `tuns` without leaking the secret to shell history

Copy `/root/pbs-tuns-token.secret` to `tuns:/root/pbs-tuns-token.secret` (mode `0600`), then on `tuns`:

```sh
# Leading space (with HISTCONTROL=ignorespace/ignoreboth) or reading from the 0600 file
# keeps the secret out of ~/.bash_history; shred the secret file on both hosts immediately after.
FP="<fingerprint-from-step-3>"
pvesm add pbs pbs-store1 \
  --server 192.168.1.98 \
  --datastore store1 \
  --username 'pve@pbs!tuns' \
  --fingerprint "$FP" \
  --password "$(cat /root/pbs-tuns-token.secret)"

shred -u /root/pbs-tuns-token.secret
ssh pbs 'sudo shred -u /root/pbs-tuns-token.secret'
```

`TODO(encryption)`: Client-side encryption decision pending (`--encryption-key` on `pvesm add` / offline paper key backup).

## 3. Verify

On `pbs`:

```sh
ssh pbs 'sudo proxmox-backup-manager datastore list'
ssh pbs 'sudo proxmox-backup-manager prune-job list'
ssh pbs 'sudo proxmox-backup-manager verify-job list'
ssh pbs 'sudo proxmox-backup-manager acl list'
```

On `tuns`:

```sh
ssh tuns 'pvesm status | grep pbs'
```

## 4. Restore drill

*(Placeholder — to be filled after the live restore drill.)*
