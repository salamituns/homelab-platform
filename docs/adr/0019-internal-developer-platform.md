# ADR 0019: Internal developer platform — hosting real apps from the lab

- Status: **Accepted on merge** (owner answered the open questions 2026-11-07; see Rev B).
  Phase 1 gate passed 2026-11-09 (see Rev C and the Phase 1 gate evidence).
  Phase 2 (govgraph) hosting decision recorded 2026-11-11 (see Rev D)
- Date: 2026-11-07
- Owner: owner
- Last reviewed: 11 Nov 2026
- Next review: after each phase gate (next: Phase 2, govgraph)

## Revision history

| Rev | Date | Change |
|---|---|---|
| A | 7 Nov 2026 | Initial proposal from the three app repos, the live cluster and the 7 Nov hardening state |
| B | 7 Nov 2026 | Owner decisions: protexa prod on a managed host (lab = pipeline + staging; protexa is demo/pilot, no live customers); govgraph DB is Supabase Postgres (moved from Neon by the owner); move both Vercel-DNS domains to Cloudflare |
| C | 9 Nov 2026 | Phase 1 (personal site) done: cut-over record and gate evidence added; runbooks [edge-public.md](../runbooks/edge-public.md) and [promoter.md](../runbooks/promoter.md) |
| D | 11 Nov 2026 | Phase 2 (govgraph) hosting decision: why govgraph exhausted Vercel's free tier, the app-side fix, traffic-spike behaviour behind Cloudflare, lab vs Vercel trade-offs, and the conditions before DNS cut-over. Corrects Phase 2 egress: web pods reach Supabase Postgres only (`:5432`/`:6543`); the refresh runs as a separate CronJob with HTTPS, Postgres and web-pod `:3000` access |

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
| **2. govgraph** | Edge rules first (cache, bots, rate limit; see Rev D); `next` profile; secrets from OpenBao; web pods egress to Supabase Postgres only (`:5432` session or `:6543` transaction pooler; the app uses `:6543` with `prepare: false`); refresh as its own `CronJob` with `CRON_SECRET`, HTTPS, Postgres and web-pod `:3000` access; revalidate every pod, then purge Cloudflare, then warm the top pages; staging refresh suspended; CPU/memory quota per govgraph namespace, staging + prod together sized to the node; DNS to Cloudflare | Page renders with live data; cron ran and the purge followed; edge cache hit ratio ≥ 90 % on HTML and graph data, measured over 7 days (the post-refresh cold start is included); SLO + logs per tenant; 7 days green |
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
  filesystem; `/healthz` returns 200; `/api/contributions` returns 404 by design (no pod egress; `site.js`
  falls back to the public contributions API in the browser).
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

## Phase 2 hosting decision: govgraph (11 Nov 2026, Rev D)

### Why govgraph exhausted Vercel's free tier

Vercel reported 27.84 GB of origin transfer in one cycle against the free tier's 10 GB, and the
account is now blocked (no builds, no deployments). The cause was in the app, not the platform:

- The homepage read `searchParams`, which made it dynamic: every visit rendered on a function and
  sent about 1.56 MB of HTML that was never cached.
- The root layout embedded the whole graph (976 nodes, 1,704 edges, about 1.2 MB of JSON) in every
  page, so entity pages were about 1.57 MB each, and ISR re-rendered them every 6 hours as well as
  after the daily refresh.

Fixed in the app repo (PR #75, merged 11 Nov 2026): pages are static or ISR with a daily backstop;
the homepage reads `layer`/`days` on the client; the graph is served once from a content-addressed,
immutable URL (`/api/graph/<digest16>`, `max-age=31536000, immutable`) that browsers and the CDN
keep until the data changes; a failed database read throws, so Next keeps the last good page.
Measured: homepage HTML 1.56 MB → 75 KB, entity HTML 1.57 MB → 92 KB, graph about 239 KB gzip,
downloaded once per data version. The repo carries `scripts/check-page-cache.mjs` (cache headers,
page budget, no embedded graph) and `scripts/check-regeneration-failure.mjs` (outage keeps the
last good page) as regression checks.

### How the lab behaves under a traffic spike

```
visitor -> Cloudflare edge --HIT--> served by Cloudflare (lab not involved)
                           --MISS-> tunnel -> public-gateway -> govgraph pods -> Supabase
                                    (home upload link, apps-node CPU)
```

| Spike | Reaches the lab | Expected outcome |
|---|---|---|
| Real readers (news story, viral post) | About one fetch per page per edge location (and per web pod, since each pod caches separately) per cache lifetime | Absorbed by the edge |
| Crawlers walking every entity page | Each unique page once per edge location and per pod, then cached; about 1,000 pages × 92 KB is under 100 MB per pass, multiplied by locations and pods, and reset by each daily purge | Absorbed, at a few hundred MB a day at most |
| Cache-busting traffic (random query strings, random paths such as unknown entity slugs or `/api/graph/<random>`) | Every request | The real risk: bounded by the home uplink, Node CPU and Supabase. Mitigations: cache keys that ignore unknown query strings, short edge caching of 404s, Bot Fight Mode, AI-crawler blocking and one rate-limit rule. Random-path floods are bounded only by the rate limit and the quota |

**Daily cold start.** The 04:00 Africa/Lagos refresh invalidates every pod's cache and purges the
whole Cloudflare zone at the same moment, so for a few minutes every page is a miss everywhere and
all pods regenerate from Supabase together. This is accepted because of the hour (low traffic in
Nigeria), and the refresh job warms the most-visited pages (`/ng` and the top entity pages) right
after the purge. A spike that lands in that window is not absorbed by the edge. The purge is
zone-wide (`purge_everything`), so the zone must hold govgraph hostnames only, and the staging
refresh stays suspended (it shares the zone, see `docs/runbooks/govgraph.md`).

Vercel scales out and bills (or blocks) under load. The lab has fixed capacity: under overload it
slows or drops requests but never produces a bill. During an origin outage the edge serves only
what it still holds: pages cached since the last purge. Cloudflare free serves stale content only
in limited cases, so availability during an outage is best effort; right after the daily purge it
is close to none. `stale-if-error` on HTML responses and Always Online are follow-ups for the app,
not guarantees.

### Options

| | Vercel (free once unblocked, or Pro) | Lab behind Cloudflare (chosen) |
|---|---|---|
| Cost | Metered; a spike or bad build blocks the account (as happened). After the fix the same traffic would likely fit the free tier, but that is an estimate, not measured | No usage bill; Cloudflare free does not meter bandwidth |
| Scaling | Automatic | Fixed; the edge cache does the scaling |
| Availability | Provider-run | One host on a home connection (D9); uncached requests fail during power or ISP outages, and little is cached in the first minutes after each daily purge |
| Operations | Revalidation and CDN purge are built in | We own the order: revalidate every pod, then purge the edge |
| Isolation | Separate from the lab | Shares `workernode3` with other tenants; needs a quota so a spike cannot starve them |
| Security | Provider's surface | Home network becomes internet-facing for app traffic (tunnel, no open ports, NetworkPolicy, read-only root filesystem) |
| Learning value | Low | High: caching, edge rules, secrets, CronJobs, per-tenant SLOs |

**Decision:** host govgraph in the lab behind Cloudflare. With the app fix, a spike costs the lab less
than it cost Vercel, and the move is the purpose of Phase 2. Vercel stays configured as the fallback
(D9) once the account is unblocked.

### Conditions before DNS cut-over

1. **Edge rules are live before traffic moves.** Cache rules for HTML and the graph data (cache key
   ignores unknown query strings), Bot Fight Mode, AI-crawler blocking, and one rate-limit rule on
   uncacheable paths. Without them the lab takes every request.
2. **Refresh ordering.** The refresh `CronJob` writes the snapshot, revalidates every web pod (each
   pod has its own cache in an `emptyDir`; the revalidation Service sets `publishNotReadyAddresses`
   so a briefly NotReady pod is not skipped), waits until each pod confirms the invalidation is
   durable, then purges Cloudflare (`purge_everything` on a govgraph-only zone), then warms the top
   pages. Purging first would let the edge re-cache stale pages. The purge token lives in OpenBao.
   Only prod refreshes on schedule; staging is suspended because it shares the zone.
3. **Split egress.** Web pods reach Supabase Postgres only (`:5432`/`:6543`, IP-wide with private,
   CGNAT and link-local ranges excepted, since the CNI cannot match hostnames). The refresh pod gets
   HTTPS for its sources and the Cloudflare API, Postgres, and `:3000` to the web pods, and the web
   pods admit the refresh pod on `:3000`.
4. **Build without database credentials.** CI builds the image without `DATABASE_URL`, and pages are
   generated on first request in the cluster. A build that can reach production data, or fails when
   it cannot, is avoided. This lands with the app's lab-container change (app repo PR #76), not PR
   #75; until it is merged, an image from the app's `main` cannot meet conditions 2 and 4.
5. **Tenant quota.** A ResourceQuota on each govgraph namespace (`govgraph-staging`,
   `govgraph-prod`), with the two together sized to leave `workernode3`'s other tenants their share,
   so an uncached flood degrades govgraph only.
6. **Outside check and alerts.** An outside uptime check (D8), an alert on edge cache hit ratio
   below 90 %, and an alert on origin egress above a daily threshold.

Residual risk: some residential ISP terms forbid hosting servers. The tunnel with edge-served
traffic keeps the origin's footprint small; the owner checks the ISP's terms.

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
