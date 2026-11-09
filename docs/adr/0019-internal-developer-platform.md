# ADR 0019: Internal developer platform — hosting real apps from the lab

- Status: **Accepted on merge** (owner answered the open questions 2026-11-07; see Rev B).
  Phase 1 gate passed 2026-11-09 (see Rev C and the Phase 1 gate evidence)
- Date: 2026-11-07
- Owner: owner
- Last reviewed: 9 Nov 2026
- Next review: after each phase gate (next: Phase 2, govgraph)

## Revision history

| Rev | Date | Change |
|---|---|---|
| A | 7 Nov 2026 | Initial proposal from the three app repos, the live cluster and the 7 Nov hardening state |
| B | 7 Nov 2026 | Owner decisions: protexa prod on a managed host (lab = pipeline + staging; protexa is demo/pilot, no live customers); govgraph DB is Supabase Postgres (moved from Neon by the owner); move both Vercel-DNS domains to Cloudflare |
| C | 9 Nov 2026 | Phase 1 (personal site) done: cut-over record and gate evidence added; runbooks [edge-public.md](../runbooks/edge-public.md) and [promoter.md](../runbooks/promoter.md) |

## Scope

In scope: turning the lab from "one demo app" into a **platform that serves several product teams**:
how an app is onboarded, built, signed, deployed, given secrets, exposed to the internet, watched,
and isolated from the other apps and from the platform itself. First tenants: three of the owner's
apps that Vercel's free tier switched off (Vercel shows them `live: false`).

Out of scope: rewriting the apps; moving app databases into the cluster (later ADR if wanted);
a second physical host (still a hardware decision, see ADR 0006 update).

## Naming rule (public repo)

This repo is public and mirrored to GitHub. App **public hostnames never go into git**: one of them is
the apex of the Gitea domain. Apps are named by ID only:

| App ID | Repo (GitHub, private/public as today) | Kind |
|---|---|---|
| `personal-site` | the owner's personal website | static HTML/CSS/JS + one cached proxy function |
| `govgraph` | ng-gov-graph | Next.js 16 server-rendered, Postgres (Supabase cloud), daily cron |
| `protexa` | Protexa AI Shield (two brands by hostname) | Vite SPA; backend is Supabase cloud (~60 edge functions) |

Hostnames, tunnel credentials and per-app env values live in OpenBao and are rendered by ESO.

## Context

- **Platform today** (7 Nov): kubeadm `v1.33.13`, one control plane + two 4 GB workers at ~66–69 % memory;
  Argo CD app-of-apps; Jenkins + `ci-agent` with fail-closed gates, Cosign signing, Nexus; Kyverno
  `Deny` on `dev`; OpenBao + ESO; default-deny NetworkPolicies; Falco; Prometheus/Loki/SLOs/dead-man;
  nightly PBS + etcd snapshots. Everything is LAN/Tailscale only, on purpose: the 25 Oct Gitea RCE
  came in through an internet-facing Cloudflare tunnel ([postmortem](../postmortems/2026-10-25-gitea-rce-cve-2026-60004.md)).
- **Single tenant shortcuts that do not scale**: images live in the `belleshop` Nexus repo (even the
  Rollouts plugin); `nexus-pull` is hand-copied into each namespace; `belleshop-deploy`, `promote.sh`
  and the Jenkinsfile are BelleShop-specific; Argo `platform` AppProject allows broad destinations.
- **Capacity**: `tuns` has ~13 GB RAM and ~3 TB thin pool free. The workers cannot take three more apps.
- **The apps' runtime needs** (read from the repos, 7 Nov):
  - `personal-site`: static files; its proxy fetches a public GitHub-contributions API and caches it 6 h.
  - `govgraph`: `next start` server; env `DATABASE_URL` (Postgres on **Supabase**, moved from Neon by the owner), `CRON_SECRET`,
    `NEXT_PUBLIC_POSTHOG_*`; daily `0 4 * * *` call to `/api/cron/refresh`.
  - `protexa`: static SPA build; all data goes browser → Supabase cloud. Brand chosen by `Host`.
    Handles **HIPAA** workloads for its customers.

## Options considered

1. **Keep paying a PaaS (Vercel Pro) and use the lab only for learning.** Zero risk, no platform
   experience gained. Rejected as the *default*; kept as the fallback for anything regulated (see protexa).
2. **Expose the lab with router port-forwards.** Opens inbound ports on a home IP; rejected (ADR 0003 reasoning).
3. **Cloudflare Tunnel (outbound-only) to a separate public entry point that can reach only app
   namespaces.** No open ports, Cloudflare WAF and caching in front, admin plane unreachable by design.
   **Chosen** (owner, 7 Nov).
4. **One namespace per app vs. one cluster per app.** One small cluster cannot afford cluster-per-app;
   namespace-per-app-per-environment with hard isolation (quota, NetworkPolicy, scoped secrets, scoped
   Argo project, PSA restricted, Kyverno) is the standard multi-tenant pattern. **Chosen.**

## Decision

### D1. Tenancy: the "tenant kit"

Each app gets namespaces `<app>-staging` and `<app>-prod`, created from one Kustomize component
`k8s/tenants/_kit/` plus a small per-app file `k8s/tenants/<app>/` (owned by the platform team):

- labels: `pod-security.kubernetes.io/enforce: restricted`, `homelab.arpa/admission: enforced`
  (Kyverno signature/digest/registry/limits policies apply), `homelab.arpa/tenant: <app>`,
  `homelab.arpa/exposure: public|internal`;
- `ResourceQuota` + `LimitRange` (defaults so a pod without limits still gets sane ones);
- NetworkPolicies: default-deny, DNS egress, ingress only from the gateway data plane that serves it,
  per-app extra egress declared in the app file (e.g. `govgraph` → Supabase Postgres `:5432`/`:6543`);
- `ExternalSecret`s: `nexus-pull` (from OpenBao, no more hand copies) and the app's own env secrets;
- a `ServiceAccount` per app and a `RoleBinding` giving the app's developer group (Gitea OIDC group
  `<app>-dev`) read + `rollouts promote/abort` in its own namespaces only.

**Golden-path test**: onboarding a fourth app must take one PR to `k8s/tenants/` + one to the deploy
repo, under an hour, with no `kubectl` by hand.

### D2. Capacity: a dedicated apps worker

Add `workernode3` (Terraform clone of template 109, 4 vCPU / 8 GB / 80 GB, static IP via
`roles/static_ip`, kubeadm join via Ansible). Label `homelab.arpa/pool=apps`, taint
`homelab.arpa/pool=apps:NoSchedule`; tenant pods get the toleration + node selector from the kit
(Kyverno mutate as a backstop). Platform pods stay on workers 1–2, so a noisy app cannot starve
Argo CD or Prometheus, and a platform incident cannot evict an app. Leaves ~5 GB host headroom.

### D3. Source of truth for app code stays on GitHub

Developers keep pushing to GitHub. Gitea holds a **pull mirror** of each app repo (read-only, token
with `contents:read`). Jenkins builds from the Gitea mirror, so CI never needs GitHub credentials and
the platform keeps working if GitHub is slow. (Verify in Phase 0 whether mirror syncs fire webhooks;
otherwise Jenkins polls the mirror every 5 min.)

### D4. CI: one pipeline template, per-app registry identity

- `ci/templates/Jenkinsfile.app`: the BelleShop pipeline generalised (gitleaks, Trivy fs, tests,
  SonarQube gate, build, Trivy image, SBOM, push, Cosign sign + attest, promote). Apps choose a build
  profile: `static` (nginx-unprivileged image serving `dist/`), `next` (Next.js standalone),
  `vite-spa`.
- Nexus: one hosted repo **per app** (`allow_once`), one push user per app, `k8s-pull` reads all app
  repos. A new hosted repo `platform` takes platform-owned images (the Rollouts plugin moves there).
- Kyverno `verify-images` extends from `belleshop/*` to every app repo with the same Cosign key.

### D5. Deploy: one apps-deploy repo, Argo CD ApplicationSet

- New Gitea repo `apps-deploy`: `apps/<app>/base` + `overlays/staging` + `overlays/prod`.
- `promote.sh` generalised: CI opens a digest-pinned PR to **staging** automatically; promotion to
  **prod** is a separate PR (the owner/app owner merges it). Same flow as BelleShop, per app.
- Argo CD: AppProject `apps` (sources: `apps-deploy` only; destinations: `*-staging`/`*-prod` only;
  no cluster-scoped resources), ApplicationSet with a git directory generator over `apps/*/overlays/*`.

### D6. Secrets: per-app paths and per-namespace access

OpenBao KV `secret/apps/<app>/<env>/*`. Each tenant namespace gets its own `SecretStore` using the
Kubernetes auth role `apps-<app>-<env>`, bound to that namespace's ServiceAccount, with a policy that
can read only its own path. One app can never read another app's secrets, and the platform's secrets
(`secret/monitoring`, OIDC clients) are out of reach.

### D7. Public edge: Cloudflare Tunnel to an apps-only gateway

- Namespace `edge-public`: `cloudflared` (2 replicas, anti-affinity, image pinned by digest, signed or
  mirrored into the `platform` repo). Egress only to Cloudflare (`443`, `7844`) and to the public
  gateway; ingress none. Tunnel credentials and the hostname → service map come from OpenBao via ESO.
- A **second Gateway `public-gateway`** (NGF, same controller, its own data plane) with **no MetalLB
  IP** (ClusterIP only, so not reachable from the LAN) and listeners whose `allowedRoutes` accept only
  namespaces labelled `homelab.arpa/exposure: public`. Admin hostnames stay on `homelab-gateway`
  (`.240`); the tunnel has no network path to them (NetworkPolicy) and no route for them (Gateway).
- Cloudflare: proxied DNS, managed WAF rules, rate limits, `Always Online`/cache for static assets,
  **Cloudflare Access** in front of every `-staging` hostname. Domains on Vercel DNS move their NS to
  Cloudflare (owner step) before cut-over.
- Origin TLS: cloudflared → `public-gateway` over HTTPS with the lab CA as `caPool` (no plaintext hop).
  **Phase 1 C (2026-11-08):** the in-cluster hop is HTTP `:80` on a ClusterIP Service.
  Cloudflare already terminates public TLS; NetworkPolicy admits only `edge-public/cloudflared`
  (no LAN). cloudflared origin `caPool` against 2026.10.7 is UNVERIFIED from this repo.
  Revisit if the extra hop must be encrypted. Hostname → origin map stays in the Cloudflare
  dashboard (this repo is public).

### D8. Observability per tenant

Logs in Loki by namespace; a blackbox Probe + availability SLO per public app (as BelleShop); alerts
labelled `tenant=<app>` and routed to the app owner. Inside probes cannot see a dead WAN or a dead
`tuns`, so each public app also gets an **outside** uptime check (healthchecks.io or Cloudflare health
check) — same lesson as the dead-man's switch.

### D9. Availability, stated honestly

One host on a home connection. Targets: `personal-site` 99.0 % (Cloudflare serves cached pages when
the origin is down), `govgraph` 99.0 % with announced maintenance windows. Vercel stays configured
but idle as the documented fallback for each app until its first 30 days on the lab are green.

## Owner decisions (7 Nov 2026)

1. **protexa production runs on a managed host** (Vercel Pro or Cloudflare Pages), deployed by the lab's
   signed pipeline. The lab runs protexa's CI/CD and a **staging** environment behind Cloudflare Access.
   protexa is demo/pilot today (no live customers), so staging may use demo data only, never real PHI.
   Reason: a compromised home lab serving protexa's JavaScript could exfiltrate PHI from browsers, and
   customers' BAAs and security reviews ask where the app is hosted.
2. **govgraph's database is Supabase Postgres** (the owner moved it from Neon). Same reasoning as a managed
   Neon: backups and patching stay with the provider, no new state in the lab. Because govgraph will run as
   a long-lived container (not serverless), use the **session** connection (`:5432`), or the transaction
   pooler (`:6543`) with `prepare: false` in `postgres.js`. Egress rule: Postgres ports only. The repo's
   leftover `neon.ts` / `@neon/*` packages should be removed in the app repo once the move is confirmed.
3. **Both Vercel-DNS domains (govgraph's and kletraq) move to Cloudflare DNS** before their cut-over phase
   (owner step at the registrar).
4. **Still open (protexa repo, not this platform):** `VITE_AXXESS_API_KEY` is read in the frontend, and every
   `VITE_*` value is embedded in the public JavaScript. If it grants access to an Axxess tenant it is already
   exposed wherever the app is hosted; it should move behind a Supabase edge function. Must be fixed before
   protexa's staging goes behind the tunnel.

## Rollout plan (phases, each a gate)

| Phase | Work | Gate (evidence) |
|---|---|---|
| **0. Platform prerequisites** | `workernode3` (D2); `nexus-pull` via ESO everywhere (closes ROADMAP item); Nexus `platform` repo + per-app repos/users; tenant kit (D1); `apps` AppProject + ApplicationSet (D5); OpenBao per-app paths + roles (D6) | A dummy app onboarded to `demo-staging` with one PR each; cross-tenant secret read denied; cross-namespace traffic denied |
| **1. personal-site** | static profile; staging behind Access; `edge-public` + `public-gateway` + tunnel (D7); outside uptime check; cut DNS from Vercel | Public URL served from the lab; admin hostnames unreachable through the tunnel (tested); WAF on; 7 days green. **Done 2026-11-09** — see the Phase 1 gate evidence below |
| **2. govgraph** | `next` profile; secrets from OpenBao; Supabase Postgres egress (session `:5432`); cron → `CronJob` with `CRON_SECRET`; DNS to Cloudflare | Page renders with live data; cron ran; SLO + logs per tenant; 7 days green |
| **3. protexa** | staging in the lab behind Access (demo data only); prod pipeline deploys to the managed host; `VITE_AXXESS_API_KEY` moved server-side first; kletraq DNS to Cloudflare | Staging behind Access, both brands by host; managed prod deployed from the signed pipeline |
| **4. Platform drills** | tunnel down, apps node loss, per-tenant secret rotation, onboard a 4th app in < 1 h | Postmortems like Week 8 |

## Phase 1 gate evidence (9 Nov 2026)

The personal site is live from the lab. Full records: [edge-public.md](../runbooks/edge-public.md)
(cut-over), [promoter.md](../runbooks/promoter.md) (the GHCR → lab promoter and its rollout bugs).

- **Pipeline + promoter live.** GitHub Actions `lab-release.yml` (push to main) builds the
  nginx-unprivileged image, runs the Trivy gate, generates the Syft SBOM, pushes the GHCR package
  `personal-site`, signs it keyless and attaches the SPDX attestation. The Jenkins job
  `personal-site-promoter` (cron H/15, `/opt/ci-gates/promote-ghcr.sh`) then verifies the keyless
  signature (issuer `token.actions.githubusercontent.com`, workflow `lab-release.yml@refs/heads/main`,
  repository claim) and the SPDX attestation, re-scans with Trivy, copies the digest preserving it
  to `registry.home.arpa/personal-site/site`, re-signs with the lab key and opens a staging PR in
  apps-deploy as `ci-promote`. First promotion: digest
  `sha256:b8e21fea3a74dc2b0aa40926a457a4041c3712446fef8fb7a9ba4b5a71335d8b`, build #4 SUCCESS,
  apps-deploy PR #3. Steady state confirmed: build #8 logged "staging overlay on main already pins
  … nothing to do", SUCCESS.
- **Admission holds.** Kyverno server dry-run in `personal-site-staging`: the promoted digest is
  admitted; a never-signed digest is denied by `verify-tenant-images`; the GHCR original is denied
  by `restrict-registries`. Only the lab-signed copy runs.
- **Workload.** Staging and prod pods run on `workernode3` as uid 101 with a read-only root
  filesystem; `/healthz` returns 200; `/api/contributions` returns 404.
- **Edge.** 2 cloudflared pods (workernode1, workernode2), 4 QUIC connections each;
  `public-gateway` is ClusterIP; `scripts/edge-isolation-test.sh` 22/22 PASS (admin hostnames
  unreachable through the tunnel — the recorded matrix is in
  [edge-public.md](../runbooks/edge-public.md)).
- **External checks after cut-over (2026-11-09).** The apex hostname returns 200 with CSP,
  nosniff, Referrer-Policy and Permissions-Policy headers and no Vercel headers; `/nginx.conf`
  is 404; http → https is 301; `www` → apex is 301 preserving path and query (one hop); the
  staging hostname 302s to Cloudflare Access; cloudflared reports 0 ERR and 0 restarts; site pods
  report 0 5xx; Argo apps `edge-public`, `nginx-gateway`, `tenants`, `personal-site-staging`,
  `personal-site-prod` are Synced/Healthy.
- Before cut-over the site on Vercel returned 402 DEPLOYMENT_DISABLED, so the cut-over restored it.
- The gate's 7-days-green window runs from the 2026-11-09 cut-over to 2026-11-16; the checks above
  are the day-zero evidence.

## Consequences

- The lab becomes internet-facing again, for app traffic only, through Cloudflare. Security work shifts
  to tenant isolation and the edge: WAF, Access on staging, no admin routes on the public gateway.
- More moving parts (a second gateway, a tunnel, an ApplicationSet, per-app identities) — each one is
  code in this repo and each phase ends with a drill-style gate.
- Real users now feel lab outages. Backups, the dead-man's switch and the outside uptime checks become
  user-facing, and maintenance needs windows.
- The Talk Track gains the platform-engineering story: golden path, tenancy, edge, per-tenant SLOs.

## References

- ADR 0011 (CI), 0012 (promotion + admission), 0013 (Gateway API), 0014 (secrets), 0015 (network
  policy), 0016 (OIDC), 0017 (SLOs), 0018 (drills); ROADMAP "Phase 2: internal developer platform".
