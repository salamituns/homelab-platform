# Postmortem: Drill 1, leaked secret (detect a token in a commit; revoke and rotate a live OIDC secret)

- Date: 2026-11-04 (evening CST; 2026-11-05 UTC)
- Severity: **Low** (planned; one admin UI logged out for a few minutes; no data at risk)
- Status: **Resolved 2026-11-04 ~20:10 CST.** Follow-ups in Action items
- Duration: detection about 1 s; rotation about 25 min end to end (owner steps, unhurried)
- Author: homelab-platform
- Drill: yes, [ADR 0018](../adr/0018-week8-chaos-drills.md) drill 1 (leaked secret)

## Summary

Two halves. **Detect:** a randomly generated fake GitHub token (`ghp_` + 36 characters, never valid) was
staged in `docs/chaos/gitleaks-canary.txt`; the pre-commit `gitleaks` hook refused the commit in about one
second (rule `github-pat`). Nothing was pushed; the branch was deleted. **Revoke and rotate:** treating the
`oauth2-proxy-alertmanager` OIDC client secret as leaked, the owner regenerated it in Gitea, stored the new one
with `scripts/openbao-breakglass.sh root-run oidc oauth2-proxy-alertmanager --overwrite` (which also issues a
new cookie secret), force-synced the ExternalSecret and restarted the gate. Login worked with the new secret;
Grafana, Argo CD and the Prometheus gate were untouched. The hypothesis held, with one gap and one procedure bug
(below).

## Timeline (America/Chicago, CST)

| When | What |
|---|---|
| 2026-11-04 19:45:23 | **Injection (detect half):** fake token staged, commit attempted with hooks on |
| 2026-11-04 19:45:24 | **Detect:** `gitleaks` pre-commit hook `Failed`, `RuleID: github-pat`, `leaks found: 1`. Commit blocked; canary branch deleted, never pushed |
| 2026-11-04 ~19:55-20:03 | **Injection (rotate half):** owner regenerated the Gitea client secret (old secret dead from this moment) and ran `root-run oidc ... --overwrite` (root token minted on sectools, revoked and verified revoked). Exact owner times not recorded |
| 2026-11-04 20:04:13 | ESO `force-sync` wrote the new `client-secret` + `cookie-secret` into `monitoring/oauth2-proxy-alertmanager` |
| 2026-11-04 20:04:34 | **Mitigate:** `oauth2-proxy-alertmanager` restarted with the new secret |
| 2026-11-04 20:06-20:07 | Five logins returned **403**: the private window was still signed in to Gitea as `homelab-bot`, which is not in `homelab:platform-admins` (`[AuthFailure] ... unauthorized`). The token exchange itself succeeded, so the new secret already worked |
| 2026-11-04 20:09:36 | **Recover:** owner signed in as `tunsgit`, `[AuthSuccess]`, Alertmanager UI loads. Grafana 302, Prometheus 302, Argo CD 200 (unaffected) |

## Root causes

1. **Detection lives only on the client and in CI.** `gitleaks` runs as a pre-commit hook and as the Jenkins
   `secrets` gate. Gitea has **no** server-side (pre-receive) scan, so `git commit --no-verify` followed by a
   push would land a secret in a repo; the first catch would then be CI, after the secret already sits in Gitea
   history. Open since the 2026-10-25 incident.
2. **The rotation procedure in ADR 0018 would not have rotated anything by itself.** The ExternalSecret has
   `refreshInterval: 1h`; restarting the gate right after `--overwrite` reloads the *old* Secret. A
   `force-sync` annotation before the restart is required (used in this drill; missing from the ADR text).
3. **The 403s were the access model working, not a fault.** A leftover Gitea session in the browser belonged
   to the bot account; the Alertmanager gate admits only `homelab:platform-admins`, so it refused. Useful
   side-proof: the agent identity cannot open the one UI that can silence alerts.

## What worked

- `gitleaks` caught a well-known token shape in about one second, before anything left the Mac.
- The break-glass path kept the OpenBao root token on sectools and revoked it automatically
  (`lookup-self -> 403`).
- One OAuth2 app per consumer kept the blast radius to one UI: no other login or token changed.
- The gate's log line named the account and the reason (`homelab-bot@home.arpa ... unauthorized`), which made
  the 403 a two-minute diagnosis.
- Must-not list held: no live token committed, `argocd-read` and `agent-pushes` untouched, no secret value in
  chat, git or this document.

## What went badly

- The "old secret is dead" proof was not captured in the gate's logs (the pre-restart pod's logs were gone
  after the restart), and the owner's step times were not written down. Next drills: write times as you go.
- The ADR rotation steps missed the ESO force-sync (root cause 2).

## Action items

- [ ] Gitea server-side secret scanning (pre-receive gitleaks or an equivalent) so `--no-verify` cannot land a
      secret; own ADR or runbook. Carried from the 2026-10-25 postmortem
- [ ] ADR 0018 drill 1 and `docs/credentials.md`: add "force-sync the ExternalSecret before restarting" to every
      OIDC rotation step (this PR)
- [ ] Postmortem template habit: keep a running timeline while doing owner steps

## Lessons

1. **A secret is rotated only when the consumer has actually reloaded it.** Storing a new value is half the job;
   know how and when each consumer picks it up (here: ESO refresh interval, then a pod restart).
2. **Scan at every layer you control.** Client hooks are a courtesy that `--no-verify` skips; the server is the
   layer an attacker or a hurried human cannot opt out of.
3. **A 403 after a successful login is information, not failure.** Read who was refused and why before
   touching the secret again.
