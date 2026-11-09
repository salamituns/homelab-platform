# Runbook: the GHCR → lab promoter (`personal-site-promoter`)

Why and what: [ADR 0019](../adr/0019-internal-developer-platform.md) D4. The personal site
builds on GitHub Actions and pushes to GHCR, signed keyless with GitHub's OIDC. The lab does
not trust that keyless identity for admission (Kyverno verifies the **lab** Cosign key), so a
promoter crosses the trust boundary: it verifies the GitHub identity, re-scans, copies the
digest into the lab registry and re-signs it with the lab key.

Script: `ci/promoters/promote-ghcr.sh` (installed at `/opt/ci-gates/promote-ghcr.sh` on
`ci-agent`). Job wiring: `ci/promoters/personal-site.Jenkinsfile` (Jenkins job
`personal-site-promoter`, cron `H/15 * * * *`, agent label `docker`). Tests:
`ci/promoters/test/promote-ghcr-test.sh` (offline harness: stubbed tools, local git remote,
fake Gitea API).

This repo is public. The GitHub source repo name (it contains the site's public domain)
arrives as the Jenkins credential `personal-site-source-repo` and is **never printed**; logs
carry digests only.

## How a release flows

1. Push to main in the source repo. GitHub Actions `lab-release.yml` builds the
   nginx-unprivileged image, runs the Trivy gate, generates the Syft SBOM, pushes the GHCR
   package `personal-site`, signs it keyless (GitHub OIDC) and attaches an SPDX attestation.
2. On its 15-minute timer the promoter runs `/opt/ci-gates/promote-ghcr.sh`:
   1. resolve `ghcr.io/<owner>/personal-site:main` to a digest (anonymous; the package is
      public). The digest is the only thing the run trusts.
   2. keyless verify: issuer `https://token.actions.githubusercontent.com`, workflow
      `lab-release.yml@refs/heads/main` in the SAN, plus the repository claim.
   3. verify the SPDX attestation with the same identity.
   4. Trivy re-scan of that exact digest (HIGH/CRITICAL with a fix available = stop).
   5. stop if apps-deploy **main's staging overlay already pins the digest** — before any
      write.
   6. `crane copy`, digest-preserving, to `registry.home.arpa/personal-site/site`.
   7. Syft SBOM of the copy, then lab-key sign + SPDX attest (`gates/sign.sh`).
   8. open a PR in apps-deploy (author `ci-promote`, branch `promote/site-<digest12>`)
      pinning the digest in the staging overlay.

`--dry-run` stops after step 4: verify only, no copy, no sign, no PR.

## How to read a build

Every log line starts `promote:`; failures print `promote: ERROR: …` and exit non-zero.

| Log line | Meaning |
|---|---|
| `promote: main is sha256:…` | digest resolved from GHCR |
| `promote: keyless signature verified (issuer …, workflow lab-release.yml@main)` | GitHub identity checked |
| `promote: SPDX attestation verified` | SBOM attestation checked with the same identity |
| `promote: trivy re-scan clean (HIGH/CRITICAL with fixes: none)` | re-scan passed |
| `promote: staging overlay on main already pins sha256:…; nothing to do` | **steady state**: nothing written, run ends SUCCESS |
| `promote: crane copy -> registry.home.arpa/personal-site/site@sha256:…` | a new digest: copy started (writes begin here) |
| `promote: lab key signature + SPDX attestation on …` | re-signed with the lab key |
| `promote: opened staging PR for sha256:…` | PR opened in apps-deploy |
| `promote: PR #… already open for promote/site-…; branch updated` | an earlier run pushed the branch but died before the PR call |
| `promote: pass` | run complete |

Reports (`reports/**`: digest resolution, signature JSON, Trivy report) are archived on every
build — digests only, never the source repo name.

## Steady state

Once apps-deploy main's staging overlay pins the digest, every later run stops before any
write: no re-copy, no re-signature, no PR. Recorded 2026-11-09: after the first promotion
(digest `sha256:b8e21fea3a74dc2b0aa40926a457a4041c3712446fef8fb7a9ba4b5a71335d8b`, build #4
SUCCESS, apps-deploy PR #3), build #8 logged "staging overlay on main already pins … nothing
to do" and finished SUCCESS. A quiet run like that between releases is normal; investigate
only when a build fails.

## Promoting to prod

The promoter only writes staging. Prod is a human PR in apps-deploy: copy the digest the
staging overlay pins into the prod overlay (ADR 0019 D5). Admission requires the same
lab-signed digest, so nothing extra is needed.

## Rollback

Revert the apps-deploy PR (staging or prod) that pinned the bad digest; Argo CD syncs the
previous digest back. The registry keeps every promoted digest (`allow_once`, no tag
overwrites), and signatures are per digest, so a revert needs no re-copy or re-sign.

## Admission (why only promoted images run)

Kyverno server dry-run in `personal-site-staging` (2026-11-09): the promoted digest is
admitted; a never-signed digest is denied by `verify-tenant-images`; the GHCR original is
denied by `restrict-registries`. Only the lab-signed copy in `registry.home.arpa` can run.

## Lessons from rollout

Every bug below was fixed with a test that fails on the old code. PR numbers are in
`homelab-platform` unless noted (the first two are in the private source repo).

| Bug | Fix |
|---|---|
| `.dockerignore` excluded `nginx.conf`, so `COPY .` would have served repo files | allowlist `COPY` (source repo PR #1) |
| base image carried fixable HIGH/CRITICAL CVEs | `apk upgrade` at build (source repo PR #1) |
| promoter re-signed on every run (the already-pinned check ran after signing) | check before writes (#108) |
| the tunnel token was assumed to be a JWT; it is base64 JSON `{a,t,s}` | shape check before minting a root token (#109) |
| `crane` download: 10 s timeout, GitHub 504 | timeout 120 s + retries (#111) |
| Jenkins `sh` is dash: `<<<` failed | POSIX rewrite + per-build `DOCKER_CONFIG` (#112) |
| credential file trailing newline; GHCR package name ≠ repo name | trim + `GHCR_IMAGE` (#113) |
| `COSIGN_KEY` in the environment acted as `--key` during keyless verify | `env -u` in `keyless()` (#114) |
| kustomize sorts keys; the overlay parser missed the digest → re-signed every run | whole-entry parser (#115) |
