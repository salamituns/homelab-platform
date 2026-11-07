# ADR 0019: Internal developer platform — hosting real apps from the lab

- Status: **Proposed** (draft for owner review, 2026-11-07)
- Date: 2026-11-07
- Owner: owner
- Last reviewed: 7 Nov 2026
- Next review: when the owner answers the open questions below, then after each phase gate

## Revision history

| Rev | Date | Change |
|---|---|---|
| A | 7 Nov 2026 | Initial proposal from the three app repos, the live cluster and the 7 Nov hardening state |

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
| `govgraph` | ng-gov-graph | Next.js 16 server-rendered, Postgres (Neon cloud), daily cron |
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
  - `govgraph`: `next start` server; env `DATABASE_URL` (Neon Postgres, external), `CRON_SECRET`,
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
  per-app extra egress declared in the app file (e.g. `govgraph` → Postgres `:5432`);
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

### D8. Observability per tenant

Logs in Loki by namespace; a blackbox Probe + availability SLO per public app (as BelleShop); alerts
labelled `tenant=<app>` and routed to the app owner. Inside probes cannot see a dead WAN or a dead
`tuns`, so each public app also gets an **outside** uptime check (healthchecks.io or Cloudflare health
check) — same lesson as the dead-man's switch.

### D9. Availability, stated honestly

One host on a home connection. Targets: `personal-site` 99.0 % (Cloudflare serves cached pages when
the origin is down), `govgraph` 99.0 % with announced maintenance windows. Vercel stays configured
but idle as the documented fallback for each app until its first 30 days on the lab are green.

## Open questions for the owner (decide before Phase 1)

1. **protexa is a HIPAA product.** Recommendation: the lab runs protexa's **pipeline and a staging
   environment behind Cloudflare Access**, but **production stays on a managed host** (Vercel Pro or
   Cloudflare Pages, deployed by the same signed pipeline). Reason: a compromised home lab serving
   protexa's JavaScript could exfiltrate customer PHI from browsers, and customers' BAAs/security
   questionnaires will ask where the app is hosted. Does protexa have live customers today?
2. **Secret in a browser bundle (protexa):** `VITE_AXXESS_API_KEY` is read in the frontend. Every
   `VITE_*` variable is embedded in the public JavaScript. If that key grants access to an Axxess
   tenant, it is exposed to anyone who loads the app today, independent of where it is hosted. It
   should move behind a Supabase edge function. (Flagged here; fix belongs in the protexa repo.)
3. `govgraph` database: keep Neon (recommended for now: managed backups, no new state in the lab) or
   move to an in-cluster Postgres later?
4. Move `kletraq` and `govgraph` DNS from Vercel to Cloudflare (needed for the tunnel)?

## Rollout plan (phases, each a gate)

| Phase | Work | Gate (evidence) |
|---|---|---|
| **0. Platform prerequisites** | `workernode3` (D2); `nexus-pull` via ESO everywhere (closes ROADMAP item); Nexus `platform` repo + per-app repos/users; tenant kit (D1); `apps` AppProject + ApplicationSet (D5); OpenBao per-app paths + roles (D6) | A dummy app onboarded to `demo-staging` with one PR each; cross-tenant secret read denied; cross-namespace traffic denied |
| **1. personal-site** | static profile; staging behind Access; `edge-public` + `public-gateway` + tunnel (D7); outside uptime check; cut DNS from Vercel | Public URL served from the lab; admin hostnames unreachable through the tunnel (tested); WAF on; 7 days green |
| **2. govgraph** | `next` profile; secrets from OpenBao; Neon egress; cron → `CronJob` with `CRON_SECRET`; DNS to Cloudflare | Page renders with live data; cron ran; SLO + logs per tenant; 7 days green |
| **3. protexa** | per owner answer to Q1: staging (and prod only if approved) | Staging behind Access, both brands by host |
| **4. Platform drills** | tunnel down, apps node loss, per-tenant secret rotation, onboard a 4th app in < 1 h | Postmortems like Week 8 |

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
