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
- Backups are still missing until week 2 (MinIO): until then, `gitea dump` runs daily via `gitea-backup.timer` into `/var/backups/gitea` (retaining 7 archives).

## Implementation notes (2026-10-26)

- **Done:** `gitea` (VMID 122, `192.168.1.97`) built via Terraform and configured by `ansible/playbooks/gitea.yml` (temporarily serving both `gitea.home.arpa` and `gitea-new.home.arpa` during parallel migration).
- **All 5 repos migrated and now private:** `scripts/migrate-gitea-repos.sh` mirrored all 5 repos at 2026-10-25 22:14 CDT (`git fsck` clean, no `rce-proof` refs, all branch/tag refs verified equal). All 5 repositories were created as **private** (4 had been public on `UbuntuNew`).
- **Token-scope lesson (`/repos/search` vs `/user/repos`):** Gitea's `GET /api/v1/user/repos` endpoint requires the `read:user` token scope in addition to repository scope. Using `GET /api/v1/repos/search` in `scripts/migrate-gitea-repos.sh` keeps the laptop token strictly at `write:repository` scope.
- **Cutover ordering lesson (self-managing Argo CD Application):** Because Argo CD reads its own Application manifest from the BelleShop repo being moved, cutover had to happen in four steps:
  1. Install the Caddy root CA (`k8s/argocd/argocd-tls-certs-cm.yaml`) and new `read:repository` Secret (`argocd/gitea-belleshop-readonly`) in the cluster.
  2. Commit and push the `repoURL` change (`https://gitea.home.arpa/tunsgit/BelleShop.git`, commit `ff129bf`) to the **new** Gitea server first.
  3. Switch DNS (`gitea.home.arpa` -> `192.168.1.97`, `ubuntunew.home.arpa` -> `192.168.1.83`).
  4. Patch the live Argo CD Application so `selfHeal` reconciles against the new server, where the manifest already matches the new URL (preventing Argo CD from reverting itself back to the old URL).
- **Old host (`UbuntuNew`, VMID 101, `.83`):** To be shut down with `onboot 0`, retained 30 days (until 2026-11-25) for the forensic snapshot, then deleted.
