# Credential inventory

Every credential the platform uses: what it can do, where it lives, and when it must be rotated.
**No secret values belong in this file.** It is public.

Review this list monthly. A credential that is not on this list should not exist.

| Credential | Scope (blast radius) | Stored in | Expires | Rotate |
|---|---|---|---|---|
| Proxmox API token `terraform@pve!homelab` | Create/modify/delete VMs **only in pool `terraform`**; clone template 109; use `local-lvm`, `vmbr0` | `.envrc` (gitignored, 0600) | Never (Proxmox default) | Yearly, or on any suspected leak. See [week-01 §4](week-01.md#4-proxmox-identity-for-terraform-least-privilege) |
| Gitea token `homelab-platform-laptop` (on rebuilt `gitea` `.97`) | `write:repository` | `.envrc` as `GITEA_TOKEN` | Never (Gitea default) | Created 2026-10-26 on the rebuilt Gitea server (migration token deleted after cutover; old `UbuntuNew` tokens die with that VM). Yearly |
| Gitea token `argocd-readonly` (on rebuilt `gitea` `.97`) | `read:repository` | k8s Secret `argocd/gitea-belleshop-readonly` (**created outside git**) | Never | Created 2026-10-26 on the rebuilt Gitea server for `https://gitea.home.arpa/tunsgit/BelleShop.git` |
| Gitea server secrets (`SECRET_KEY`, `INTERNAL_TOKEN`, `JWT_SECRET`, `LFS_JWT_SECRET`) | Decrypt stored credentials; act as Gitea internally | `gitea:/etc/gitea/secrets/*` (root:git 0640, loaded via `*_URI` in `app.ini`; SQLite DB has no password) | n/a | Generated on host at first boot 2026-10-25 ([ADR 0005](adr/0005-gitea-rebuild.md)). Old `UbuntuNew` secrets retired with that host |
| Caddy local root CA for `gitea.home.arpa` | Public CA certificate trusted by the Mac keychain, git (`http.sslCAInfo`), and Argo CD (`k8s/argocd/argocd-tls-certs-cm.yaml`). Private key stays on `gitea` | Public cert committed at `ansible/files/ca/gitea-caddy-root.crt`; private key in `gitea:/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.key` | 10 years (Caddy default) | Replaced by the lab CA in week 6 |
| GitHub fine-grained token `gitea-push-mirror-homelab-platform` | **Contents read/write on the public `homelab-platform` mirror repo only** | Gitea push-mirror settings on the rebuilt `gitea` (encrypted with its `SECRET_KEY`; never on disk) | 90 days (fine-grained token) | Old token revoked 2026-10-25 (readable by the Gitea attacker); new one created 2026-10-26. Rotate before expiry |
| Tailscale auth key (`TS_AUTHKEY`) | Enroll ONE device as `tag:homelab-gateway`. Single-use, pre-authorized | `.envrc`, only until enrollment; then delete the line | 1 day | Not reused: create a new one per enrollment |
| Tailscale node key of `gateway` | That device's identity on the tailnet; can reach only what `tailscale/policy.hujson` grants | `gateway:/var/lib/tailscale` | Never (tagged device) | Remove the device in the admin console if `gateway` is compromised |
| Tailscale node key of `tuns` (break-glass) | Hypervisor's identity on the tailnet; reachable only on the ports granted to `tag:homelab-breakglass` | `tuns:/var/lib/tailscale` | Never (tagged device) | Remove the device in the admin console if lost or compromised |
| Gitea credential for BelleShop | Gitea user's repo access over HTTPS | macOS keychain (moved out of `.git/config` on 2026-10-24) | Unknown | Consider rotating: it sat in plaintext in a config file |
| SSH key `~/.ssh/id_rsa` (Mac) | Login as `tunsadmin` on every VM; root on `tuns` | Mac `~/.ssh` | Never | Plan: replace with ed25519, then remove RSA from `authorized_keys` everywhere |
| SSH key `root@tuns` (`/root/.ssh/id_rsa` on the hypervisor) | Root SSH from the hypervisor. Old key `fZPN...` was authorized on every legacy VM | `tuns` only | Never | Rotated 2026-10-24 (old key exposed, see [postmortem](postmortems/2026-10-24-hypervisor-key-exposure.md)). New key `WcgvLIyj...` must not be authorized on any guest or in Gitea |
| Ansible Vault `group_vars/all/vault.yml` (legacy, on `tuns`) | Unknown; not reviewed | `tuns:~/ansible` | n/a | Review contents when the legacy project is retired |
| Gmail app password for PVE SMTP endpoint `gmail` | Sends PVE warning/error notifications to the configured mailbox | Env `PVE_SMTP_PASSWORD` at apply time; on `tuns` in `/etc/pve/priv/notifications.cfg` (root-only pmxcfs) | Until Google rotation | When leaked, when Google revokes app passwords, or yearly |

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
- **Resolved 2026-10-25 (`~/.curlrc`):** `~/.curlrc` on the admin Mac contained `-k`, silently disabling TLS certificate verification for every `curl` call since 2025-06. Disabled by the owner; repo scripts now invoke `curl -q` so a user `curlrc` cannot weaken TLS checks.
