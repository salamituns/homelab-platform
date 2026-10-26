# Runbook: Proxmox VE hypervisor (`tuns`)

Host: `tuns` (`192.168.1.181`, `https://proxmox.home.arpa:8006/`, Proxmox VE 9.1 on Debian 13).

## 1. SSH access

`ansible/playbooks/proxmox-ssh.yml` hardens SSH on `tuns` to key-only authentication by writing `/etc/ssh/sshd_config.d/10-homelab.conf`:

```ini
# managed by homelab-platform (playbooks/proxmox-ssh.yml)
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
```

Why a drop-in:
- `/etc/ssh/sshd_config` on Debian 13 has `Include /etc/ssh/sshd_config.d/*.conf` at line 12, before `PermitRootLogin yes` at line 33. Because `sshd` uses the **first** value it reads for each directive, the drop-in overrides the stock setting without modifying Proxmox's managed `/etc/ssh/sshd_config`.
- `/root/.ssh/authorized_keys` is a symlink to `/etc/pve/priv/authorized_keys` on the Proxmox cluster filesystem (`pmxcfs`). The playbook checks that it contains at least one public key before applying the drop-in, and never writes or `chmod`s it.

### Apply and verify

```sh
cd ~/homelab-platform/ansible
ansible-playbook playbooks/proxmox-ssh.yml --limit tuns --check --diff
ansible-playbook playbooks/proxmox-ssh.yml --limit tuns

# Verify effective merged sshd configuration (prohibit-password prints as without-password)
ssh tuns 'sshd -T | grep -E "permitrootlogin|passwordauth"'
# Expected:
#   permitrootlogin without-password
#   passwordauthentication no

# Confirm password authentication is rejected
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive root@192.168.1.181 true
# Expected: Permission denied (publickey).
```

### Rollback (if SSH keys ever stop working)

Open the Proxmox web console (`https://proxmox.home.arpa:8006/` -> node `tuns` -> **Shell**) or a physical/iDRAC console and run:

```sh
rm /etc/ssh/sshd_config.d/10-homelab.conf && systemctl reload ssh
```

## 2. Two-factor login (`root@pam`)

Disabling SSH password login does **not** affect the Proxmox web UI (`:8006`), which authenticates `root@pam` via PAM directly (`pvedaemon` / `pveproxy`). Protect the web UI with TOTP two-factor authentication:

1. In the Proxmox web UI, go to **Datacenter** -> **Permissions** -> **Two Factor**.
2. Click **Add** -> **TOTP**, scan the QR code in your authenticator app, and verify a code.
3. Click **Add** -> **Recovery Keys** and store the one-time recovery keys **offline** (outside the lab).
4. Note: SSH access is unaffected by Proxmox TFA because SSH uses public-key authentication only (`prohibit-password`).

## 3. Backups (hypervisor side)

`ansible/playbooks/proxmox-backup.yml` configures PVE's notification system (not postfix) and one opt-out vzdump job:

| Item | Value |
|---|---|
| SMTP endpoint | `gmail` → `smtp.gmail.com:465` with `mode=tls` (PVE default; implicit TLS, no STARTTLS upgrade) |
| Matcher | `warning-error-gmail` matches severity `warning` and `error`, target `gmail`. Builtin `mail-to-root` is left alone |
| Job | `daily-all`: `--all 1`, exclude VMIDs `101` (forensic UbuntuNew) and `123` (PBS), snapshot, `*-*-* 01:30:00`, storage `pbs-store1` |
| Prune | Not set on the job (`--remove 0`). Retention is PBS-side; the PVE token must not delete |
| Retired | `weekly-critical` and `monthly-important` are deleted **after** `daily-all` exists. Storage `backup-3tb` and its archives stay |

The playbook refuses to apply if `pvesm status` / `pvesh get /nodes/tuns/storage` does not show `pbs-store1` as active.

### Gmail app password

1. Google account → **Security** → **2-Step Verification** → **App passwords**.
2. Create an app password (16 characters). Spaces in the Google UI are optional; paste the 16 characters.
3. Use that as `PVE_SMTP_PASSWORD`. Do not use the Google account password.

### Addresses without putting them in git

`host_vars/tuns.yml` holds `CHANGE_ME@home.arpa` placeholders. Override at apply time (preferred: environment, so nothing extra is committed):

```sh
export PVE_SMTP_FROM="you@home.arpa"          # example only; use the real mailbox
export PVE_SMTP_TO="you@home.arpa"
export PVE_SMTP_USERNAME="you@home.arpa"      # Gmail SMTP username is the mailbox
```

Put the three `export PVE_SMTP_FROM/TO/USERNAME` lines in your gitignored `.envrc` (see `.envrc.example`). Not a `host_vars/tuns.secret.yml`: Ansible only auto-loads `host_vars/tuns.yml` or `host_vars/tuns/`, so such a file would be silently ignored. **Never** put the app password in a file; it is env-only.

`vars_prompt` is not used: it breaks `--check --diff` and non-interactive runs.

### Apply (password stays out of shell history)

```sh
cd ~/homelab-platform/ansible
# Hidden prompt; the value is not written to ~/.bash_history
read -rs PVE_SMTP_PASSWORD
export PVE_SMTP_PASSWORD
# Optionally: export PVE_SMTP_FROM PVE_SMTP_TO PVE_SMTP_USERNAME

ansible-playbook playbooks/proxmox-backup.yml --limit tuns --check --diff
ansible-playbook playbooks/proxmox-backup.yml --limit tuns
unset PVE_SMTP_PASSWORD
```

The password is written on `tuns` to `/etc/pve/priv/notifications.cfg` (documented PVE secret file). It is never passed as `pvesh --password`, because that lands in process argv / `ps`.

### Test notification

Verified path on PVE 9.1.2:

```sh
ssh tuns 'pvesh create /cluster/notifications/targets/gmail/test'
```

The same action is **Datacenter → Notifications → gmail → Test**. You should get a mail at `PVE_SMTP_TO`. If it fails, the SMTP endpoint exists but auth or Gmail "less secure/app password" is wrong; `/etc/pve/priv/notifications.cfg` must contain the `smtp: gmail` password stanza.

### Run the job once by hand

Do not wait for 01:30:

1. Proxmox UI: **Datacenter → Backup → daily-all → Run now**.
2. Or copy the job's options onto a one-shot vzdump (root on `tuns`):

```sh
pvesh create /nodes/tuns/vzdump \
  --job-id daily-all \
  --storage pbs-store1 \
  --all 1 \
  --exclude 101,123 \
  --mode snapshot \
  --notification-mode notification-system
```

Watch **Datacenter → Backup → Backup jobs** / task log. Confirm VMIDs 101 and 123 are skipped.

### Rollback

Leaves `backup-3tb` and every archive on it untouched.

```sh
# Remove the new job and notification objects
pvesh delete /cluster/backup/daily-all
pvesh delete /cluster/notifications/matchers/warning-error-gmail
pvesh delete /cluster/notifications/endpoints/smtp/gmail

# Recreate the old jobs only if you still need them (they were failing / disabled):
pvesh create /cluster/backup --id weekly-critical --storage backup-3tb \
  --vmid 101,105,108 --mode snapshot --schedule 'sun 02:00' --compress zstd \
  --mailnotification failure --notes-template '{{guestname}}' \
  --prune-backups keep-last=2,keep-weekly=4 --enabled 1
pvesh create /cluster/backup --id monthly-important --storage backup-storage \
  --vmid 102,103,104,106,107,111 --mode snapshot --schedule '*-*-01 03:00' --compress zstd \
  --mailnotification failure --notes-template '{{guestname}}' \
  --prune-backups keep-last=1 --enabled 0
```
