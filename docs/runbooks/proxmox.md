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
