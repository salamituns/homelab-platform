# Credential inventory

Every credential the platform uses: what it can do, where it lives, and when it must be rotated.
**No secret values belong in this file.** It is public.

Review this list monthly. A credential that is not on this list should not exist.

| Credential | Scope (blast radius) | Stored in | Expires | Rotate |
|---|---|---|---|---|
| Proxmox API token `terraform@pve!homelab` | Create/modify/delete VMs **only in pool `terraform`**; clone template 109; use `local-lvm`, `vmbr0` | `.envrc` (gitignored, 0600) | Never (Proxmox default) | Yearly, or on any suspected leak. See [week-01 §4](week-01.md#4-proxmox-identity-for-terraform-least-privilege) |
| Gitea token `homelab-platform-laptop` | `write:repository` | `.envrc` as `GITEA_TOKEN` | Never (Gitea default) | Recreated 2026-10-25 after the Gitea incident. Yearly |
| Gitea token `argocd-readonly` | `read:repository` | k8s Secret `argocd/gitea-belleshop-readonly` (**not in git**) | Never | Created 2026-10-25. Replaces a write-scoped token that was committed to a public repo |
| Gitea server secrets (`SECRET_KEY`, `INTERNAL_TOKEN`, JWT secrets, DB password) | Decrypt stored credentials; act as Gitea internally; full DB | `UbuntuNew:/etc/gitea/app.ini` (root:git 0640) | n/a | Rotated 2026-10-25 (`SECRET_KEY` had never been set) |
| GitHub fine-grained token `gitea-push-mirror-homelab-platform` | **Contents read/write on `salamituns/homelab-platform` only** | Gitea push-mirror settings (never on disk) | Revoked 2026-10-25 | **Revoked** (readable by the Gitea attacker). Create a new one when the mirror is re-added |
| Tailscale auth key (`TS_AUTHKEY`) | Enroll ONE device as `tag:homelab-gateway`. Single-use, pre-authorized | `.envrc`, only until enrollment; then delete the line | 1 day | Not reused: create a new one per enrollment |
| Tailscale node key of `gateway` | That device's identity on the tailnet; can reach only what `tailscale/policy.hujson` grants | `gateway:/var/lib/tailscale` | Never (tagged device) | Remove the device in the admin console if `gateway` is compromised |
| Tailscale node key of `tuns` (break-glass) | Hypervisor's identity on the tailnet; reachable only on the ports granted to `tag:homelab-breakglass` | `tuns:/var/lib/tailscale` | Never (tagged device) | Remove the device in the admin console if lost or compromised |
| Gitea credential for BelleShop | Gitea user's repo access over HTTPS | macOS keychain (moved out of `.git/config` on 2026-10-24) | Unknown | Consider rotating: it sat in plaintext in a config file |
| SSH key `~/.ssh/id_rsa` (Mac) | Login as `tunsadmin` on every VM; root on `tuns` | Mac `~/.ssh` | Never | Plan: replace with ed25519, then remove RSA from `authorized_keys` everywhere |
| SSH key `root@tuns` (`/root/.ssh/id_rsa` on the hypervisor) | Root SSH from the hypervisor. Old key `fZPN...` was authorized on every legacy VM | `tuns` only | Never | Rotated 2026-10-24 (old key exposed, see [postmortem](postmortems/2026-10-24-hypervisor-key-exposure.md)). New key `WcgvLIyj...` must not be authorized on any guest or in Gitea |
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
