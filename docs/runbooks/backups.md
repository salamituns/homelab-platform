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

Publish the `pbs.home.arpa` record (it is in `group_vars/all/dns.yml`, but only `gateway` serves it):

```sh
ansible-playbook playbooks/dns.yml --limit gateway
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder   # macOS caches the earlier "no such name"
```

The UI is `https://` only. Its certificate is self-signed until week 6: before accepting it in the browser,
compare its SHA-256 fingerprint with `ssh tunsadmin@192.168.1.98 'sudo proxmox-backup-manager cert info'`.

### Step 2: Set `root@pam` password and enable TOTP on `pbs`

1. Set the Linux `root` password on `pbs` (used only by `root@pam` in the PBS web UI; root SSH remains disabled by `baseline`):
   ```sh
   ssh -t tunsadmin@192.168.1.98 'sudo passwd root'
   ```
2. Open `https://pbs.home.arpa:8007/`, log in as `root@pam`, go to **Configuration** -> **Access Control** -> **Two Factor**, and add a **TOTP** factor plus offline **Recovery Keys**.

### Step 3: Create `pve@pbs` and least-privilege token `pve@pbs!tuns` on `pbs`

Run on `pbs` as `root`:

```sh
ssh tunsadmin@192.168.1.98
sudo -i

# Create the pve@pbs user (no password needed; only its API token is used)
proxmox-backup-manager user create pve@pbs --comment "Proxmox VE hypervisor (tuns)"

# Generate the API token and write the secret directly to a 0600 file (never echoed)
umask 0077
proxmox-backup-manager user generate-token pve@pbs tuns \
  --comment "Append-only backup token for tuns" \
  --output-format json \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["value"])' > /root/pbs-tuns-token.secret

# A token's effective rights = its own ACL INTERSECTED with its user's ACL. Both need the role,
# or the token sees nothing (symptom on tuns: "Cannot find datastore 'store1'").
proxmox-backup-manager acl update /datastore/store1 DatastoreBackup --auth-id pve@pbs
proxmox-backup-manager acl update /datastore/store1 DatastoreBackup --auth-id 'pve@pbs!tuns'

# Read the PBS TLS certificate SHA-256 fingerprint for pvesm on tuns
proxmox-backup-manager cert info | grep Fingerprint
```

> **Ownership note:** With `DatastoreBackup`, `pve@pbs!tuns` can only append to backup groups owned by `pve@pbs!tuns`. Do not run test backups as `root@pam` first, or subsequent runs as `pve@pbs!tuns` will fail the owner check (`proxmox-backup-manager datastore change-owner` fixes ownership if needed).

### Step 4: Register `pbs-store1` on `tuns` (from the Mac)

```sh
scripts/connect-pve-to-pbs.sh      # ends with: OK: pbs-store1 is active; secret file on pbs shredded.
```

Why a script: the commands cross three machines (Mac, `tuns`, `pbs`), the token id contains `!` (bash
history expansion), and PVE's order of operations is not obvious. `pvesm add` test-connects an **enabled**
PBS storage, which needs the secret, and it **deletes** any existing `.pw` file when `--password` is not
given. So the script adds the storage disabled, streams the secret from `pbs` into
`/etc/pve/priv/storage/pbs-store1.pw` (never on the Mac's disk or in argv), then enables it.
If it fails, the secret stays on `pbs` and the script can simply be re-run.

`TODO(encryption)`: Client-side encryption decision pending (`--encryption-key` on `pvesm add` / offline paper key backup).

## 3. Verify

On `pbs`:

```sh
ssh tunsadmin@192.168.1.98 'sudo proxmox-backup-manager datastore list'
ssh tunsadmin@192.168.1.98 'sudo proxmox-backup-manager prune-job list'
ssh tunsadmin@192.168.1.98 'sudo proxmox-backup-manager verify-job list'
ssh tunsadmin@192.168.1.98 'sudo proxmox-backup-manager acl list'
```

On `tuns`:

```sh
ssh tuns 'pvesm status | grep pbs'
```

## 4. Restore drill

*(Placeholder — to be filled after the live restore drill.)*
