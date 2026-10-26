# ADR 0005: Rebuild Gitea on a fresh, code-built VM

- Status: Accepted
- Date: 2026-10-25

## Context

`UbuntuNew` ran attacker-supplied code as the `git` user ([postmortem](../postmortems/2026-10-25-gitea-rce-cve-2026-60004.md)).
It was patched and its secrets rotated, but the second-stage payload is unknown, so the host cannot
be proven clean. It was also hand-built: nobody knew it had ufw, an unset `SECRET_KEY`, or a
retired subnet in its firewall. Data to carry over is small: 5 repos (116 MB), 1 user,
0 issues, 0 releases.

## Decision

| Question | Choice | Why |
|---|---|---|
| Host | New VM `gitea` (VMID 122, 192.168.1.97) from Terraform | Same path as `sectools` and `gateway`: rebuildable, no inherited template keys |
| Config | Ansible role `gitea`; baseline role first | Every setting in git and reviewed, instead of discovered later |
| Migration | **Import git data, not server state**: fresh install, repos pushed in with `git push --mirror` from verified clones | A copied database or data directory could carry attacker changes (hooks, configs, accounts, tokens). Git objects are content-addressed and checked with `git fsck` |
| Version | Pinned in the role (`gitea_version`), binary verified by SHA-256 | Upgrades become a reviewed one-line change, not a forgotten task |
| Database | SQLite | One user, 5 repos: no DB server and no DB password to leak. Revisit if the lab grows |
| TLS | Caddy in front with its internal CA (`tls internal`), Gitea on 127.0.0.1:3000 | Tokens no longer cross the LAN in clear text. The CA root is trusted on the Mac and in Argo CD. Replaced by the lab CA in week 6 |
| Registration | Off; admin created by CLI | The CVE-2026-60004 entry point |
| Gitea SSH | Off (HTTPS only) | One less listener; HTTPS + tokens is enough for 1 user |
| Actions | Off until week 3 | The only runner mounts the host Docker socket (2026-10-24 postmortem) |
| Network | ufw: 443 from the k8s nodes, `gateway`, the Mac; 22 per baseline. Not published to the internet | Same clients as today, nothing else on the LAN |
| Secrets | Generated on the host by `gitea generate secret` on first run, never in git | Same rule as every other credential |
| Old host | Shut down after cutover, kept 30 days (snapshots hold the evidence), then deleted | |

## Consequences

- Clients change URL to `https://gitea.home.arpa/` and must trust the Caddy root CA.
- Repo settings that live in the DB (collaborators, webhooks, branch protection) are re-created
  by hand; there is one webhook today.
- Backups are still missing until week 2 (MinIO): until then, `gitea dump` to `tuns` by cron.
