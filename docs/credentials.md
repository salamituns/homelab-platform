# Credential inventory

Every credential the platform uses: what it can do, where it lives, and when it must be rotated.
**No secret values belong in this file.** It is public.

Review this list monthly. A credential that is not on this list should not exist.

| Credential | Scope (blast radius) | Stored in | Expires | Rotate |
|---|---|---|---|---|
| Proxmox API token `terraform@pve!homelab` | Create/modify/delete VMs **only in pool `terraform`**; clone template 109; use `local-lvm`, `vmbr0` | `.envrc` (gitignored, 0600) | Never (Proxmox default) | Yearly, or on any suspected leak. See [week-01 §4](week-01.md#4-proxmox-identity-for-terraform-least-privilege) |
| Gitea token `homelab-platform-laptop` | `write:repository`, `read:user` for the Gitea user | `.envrc` as `GITEA_TOKEN` | Never (Gitea default) | Yearly. Gitea, Settings, Applications |
| GitHub fine-grained token `gitea-push-mirror-homelab-platform` | **Contents read/write on `salamituns/homelab-platform` only** | Gitea push-mirror settings (never on disk) | **~2027-01-22 (90 days)** | Before expiry: new token on GitHub, paste into Gitea, Mirror Settings |
| Gitea credential for BelleShop | Gitea user's repo access over HTTPS | macOS keychain (moved out of `.git/config` on 2026-10-24) | Unknown | Consider rotating: it sat in plaintext in a config file |
| SSH key `~/.ssh/id_rsa` (Mac) | Login as `tunsadmin` on every VM; root on `tuns` | Mac `~/.ssh` | Never | Plan: replace with ed25519, then remove RSA from `authorized_keys` everywhere |
| SSH key `root@tuns` (`/root/.ssh/id_rsa` on the hypervisor) | Root SSH from the hypervisor. Old key `fZPN...` was authorized on every legacy VM | `tuns` only | Never | **Rotation pending**: exposed on DockerApp, see [postmortem](postmortems/2026-10-24-hypervisor-key-exposure.md). New key must not be authorized on any guest |
| Ansible Vault `group_vars/all/vault.yml` (legacy, on `tuns`) | Unknown; not reviewed | `tuns:~/ansible` | n/a | Review contents when the legacy project is retired |

## Rules

1. **Least privilege first.** Before creating a credential, write down what it can destroy if it leaks.
2. **Never in git, never in URLs.** Secrets go in `.envrc` (gitignored), the OS keychain, or the
   consuming system (e.g. Gitea mirror settings). `gitleaks` runs on every commit to catch mistakes.
3. **Expiry by default.** Prefer tokens that expire. Put the rotation date in a calendar.
4. **Leaked = rotated.** Removing a secret from a file or git history does not un-leak it.

## Known gaps

- Proxmox and Gitea tokens do not expire. Week 5 (Vault) is where short-lived credentials arrive.
- Old keys still installed: `root` on `Master` has an authorized key; `tunsdevops` has a key on
  `WorkerNode2`. Both are blocked by sshd today (`PermitRootLogin no`, `AllowUsers`), but should be removed.
