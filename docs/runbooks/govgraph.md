# Runbook: govgraph tenant (Phase 2)

Why and what: [ADR 0019](../adr/0019-internal-developer-platform.md) Rev D (Phase 2
hosting) and D1–D9. Second public tenant after `personal-site`. Next.js 16, Postgres
on Supabase, daily refresh CronJob. This repo stays hostname-free; public names are
written here as `<govgraph-host>` / `<govgraph-staging-host>`.

Do not `kubectl apply` from this document until the owner is cutting over. Platform
YAML is in `k8s/tenants/govgraph/`. Workloads (Deployment, Service, headless Service,
CronJob, HTTPRoute) live in **apps-deploy**, not this repo.

## Quota

The numbers are the tenant overlays, not this page:

- [`k8s/tenants/govgraph/staging/kustomization.yaml`](../../k8s/tenants/govgraph/staging/kustomization.yaml)
- [`k8s/tenants/govgraph/prod/kustomization.yaml`](../../k8s/tenants/govgraph/prod/kustomization.yaml)

Container requests and limits are the apps-deploy manifests (`apps/govgraph`). `workernode3` is a 4-core / 8 Gi node, and the kit default per namespace plus `personal-site` would oversubscribe it. A web rollout surge plus one refresh pod has to fit the namespace quota. Limits are ceilings. Raise the overlay if the app needs more; do not remove the quota.

## Split egress

kube-network-policies v1.1.2 is **post-DNAT** and cannot match a hostname, so
Supabase is an IP-wide TCP `:5432` + `:6543` allow with the private ranges except'd
(RFC1918, plus `100.64.0.0/10` CGNAT/Tailscale and `169.254.0.0/16` link-local — LAN
Postgres stays closed). Web pods have no `:443`. Refresh pods get `:443` except the
private ranges (and therefore except the cluster pod/Service ranges under `10.0.0.0/8`),
`:5432`/`:6543` the same way, and TCP 3000 to web pods. Public-gateway ingress is the kit
policy, patched to `component=web` port 3000, plus refresh→web `:3000`, plus Prometheus
(monitoring namespace) → web `:3000` for the day the app serves `/metrics`; today it does
not, so nothing scrapes the web pods.

## Owner steps (in order)

### 1. OpenBao paths and roles

```sh
scripts/openbao-breakglass.sh root-run tenant govgraph staging --dry-run
scripts/openbao-breakglass.sh root-run tenant govgraph staging
scripts/openbao-breakglass.sh root-run tenant govgraph prod --dry-run
scripts/openbao-breakglass.sh root-run tenant govgraph prod
```

Roles: `tenant-govgraph-staging`, `tenant-govgraph-prod`. The policy written by that
script (tenant mode) is read on `secret/data/apps/govgraph/<env>/*` and
`secret/data/platform/nexus-pull` only. The `/*` is children. The object
`secret/data/apps/govgraph/<env>` itself is not granted, and a read of it is 403.
Details: [tenant-secrets.md](tenant-secrets.md).

Then write the child objects with `root-run govgraph-secrets` (never print values; never
commit them). `DATABASE_URL` is prompted hidden and shape-checked locally (postgres scheme,
a host, port 5432/6543) before anything is contacted, and internal whitespace is refused —
only leading/trailing whitespace is trimmed — so a bad paste is never silently stored as a
different value; `CRON_SECRET` is **generated on sectools** (32 random bytes, hex) — never
prompted, never on the Mac, never printed. Prod additionally prompts hidden for
`CF_ZONE_ID` (32 hex characters) and `CF_API_TOKEN` and writes the cloudflare object;
staging writes no cloudflare object. Re-running without `--overwrite` refuses the existing
objects and keeps `CRON_SECRET`, so web and refresh stay in agreement, and the skip path
verifies what is actually stored (key set + `CRON_SECRET` shape, not just that the path
exists); `--overwrite` replaces both objects, regenerating `CRON_SECRET`;
`--overwrite-app` rotates only the app object, and `--overwrite-cloudflare` (prod only)
rotates only the Cloudflare object while keeping `CRON_SECRET` byte-for-byte — use that one
for a token rotation so the web and refresh cron secrets stay in agreement. Exactly one of
the three flags may be passed. Values travel local variable → jq environment
→ ssh stdin payload → remote environment, never argv on either side, and the command
prints only the key names written plus each path's version:

```sh
scripts/openbao-breakglass.sh root-run govgraph-secrets staging --dry-run
scripts/openbao-breakglass.sh root-run govgraph-secrets staging
scripts/openbao-breakglass.sh root-run govgraph-secrets prod --dry-run
scripts/openbao-breakglass.sh root-run govgraph-secrets prod
```

| KV object (`secret/` prefix) | Keys | Read by |
|---|---|---|
| `apps/govgraph/<env>/app` | `DATABASE_URL`, `CRON_SECRET` | Secret `govgraph` (web) and `govgraph-refresh`, that env |
| `apps/govgraph/prod/cloudflare` | `CF_ZONE_ID`, `CF_API_TOKEN` | Prod Secret `govgraph-refresh` only |

`CF_API_TOKEN` is a Cloudflare API token with **Zone.Cache Purge** on the govgraph
zone **only** (not account-wide, not DNS edit).

**Staging does not purge.** Staging and prod sit in the same Cloudflare zone, and a
purge clears the whole zone, so a staging refresh would also drop prod's edge cache.
If staging also points at the prod Supabase database, it would write the same
snapshot twice a day. So the staging CronJob ships with `suspend: true`, and there
is no `apps/govgraph/staging/cloudflare` object. The staging refresh ExternalSecret
reads only `apps/govgraph/staging/app`, and the staging CronJob sets
`REFRESH_PURGE=skip` (app PR #78). A hand trigger
(`kubectl create job --from=cronjob/govgraph-refresh`) therefore **runs the whole
sequence and does write a snapshot** to staging's `DATABASE_URL`, then skips only the
purge. If staging's `DATABASE_URL` is the prod Supabase database, a hand trigger is
a real refresh of prod data (but never a purge); use a separate staging database if
that matters. Until the staging image contains PR #78, `REFRESH_PURGE` is ignored and a
hand trigger fails at `CF_ZONE_ID is required` before persisting. Only prod
refreshes on schedule. There is no `WARM_BASE_URL` in either environment.

Gitea group `govgraph-dev` must exist; the tenant RoleBinding subjects that group.

**Probe targets (monitoring, not tenant paths).** The request-health alerts probe the
public paths, like personal-site's. The two govgraph URLs live in the existing
`monitoring/public-site-probes` KV object (keys `govgraph_apex_url`,
`govgraph_staging_url`) so the SecretStore, ServiceAccount and OpenBao role are reused.
Write them with `root-run govgraph-probes`, ideally **before the platform PR merges**; if
it has already merged, the probe-targets ExternalSecret simply sits unsynced until this
runs, and this is what unblocks it — ESO renders all four target files from that one
object, so until both keys exist the ExternalSecret cannot sync; the git bootstrap keeps
`[]` for govgraph, so its alerts stay silent, not wrong. The mode PATCHes only the two
govgraph keys into the shared object (created by `root-run public-site-probes`), keeping
`apex_url`/`staging_url` untouched, and writes with a KV v2 check-and-set on the version
it just read — if another writer races the run, the write fails and re-running is safe.
It refuses existing govgraph keys without `--overwrite`, and it refuses before writing
anything a stray key (either mode does; a human must remove it) or a lone govgraph key
(`--overwrite` repairs a lone key; a missing `apex_url`/`staging_url` base pair is
repaired by `root-run public-site-probes --overwrite`). `public-site-probes` likewise
carries the govgraph keys over on its writes, so the two modes cannot clobber each
other. Both URLs are prompted hidden, must
be `https` and end in a slash, and are verified by key set and length, never printed:

```sh
scripts/openbao-breakglass.sh root-run govgraph-probes --dry-run
scripts/openbao-breakglass.sh root-run govgraph-probes
```

### 2. Platform PR (this repo)

Already the `tenant-govgraph` change: namespaces, quota, NetworkPolicies, ESO,
`eso-tokenreview-tenants`, promoter job. Merge and wait for Argo Application
`tenants` to sync `govgraph-staging` and `govgraph-prod`.

Promoter credentials (gitignored `private/`, JCasC — a UI credential is wiped on the
next `playbooks/jenkins.yml` run):

| File | Jenkins credential |
|---|---|
| `private/govgraph-source-repo` | `govgraph-source-repo` (`owner/repo`, never echoed) |
| `private/govgraph-promoter-watchdog-url` | `govgraph-promoter-watchdog-url` (healthchecks ping; period 15m; **not** the personal-site URL) |

`push-govgraph` is created by the nexus role (`/etc/nexus/secrets/push-govgraph`).
Re-run `playbooks/jenkins.yml` after the files exist. The job is created only when both
credentials are present (the role skips it and says why otherwise).

The promoter verifies the keyless identity of the GitHub workflow **`lab-release.yml` on
`main`** (`GHCR_WORKFLOW`, default `lab-release.yml` — the govgraph release workflow must
keep that file name and branch; see [promoter.md](promoter.md)).

### 3. apps-deploy PR (private repo)

Digest-pin `registry.home.arpa/govgraph/web` after `govgraph-promoter` opens the
staging PR. The prod overlay merges dark: `web` replicas 0 and CronJob
`suspend: true`, so merging it does not serve traffic and does not purge. The human
promotion PR sets replicas to 1, `suspend` to false, and copies the staging digest.
Shapes below omit container resources; those live in apps-deploy `apps/govgraph`.
Hostnames there are `govgraph.invalid` and `staging.govgraph.invalid` until the
owner replaces them. This repo stays hostname-free (`<govgraph-host>` /
`<govgraph-staging-host>`).

Labels the platform NetworkPolicies select:

- `app.kubernetes.io/name: govgraph`
- `app.kubernetes.io/component: web` or `refresh`

Deployment **name must be `web`** (alert `GovgraphProdUnavailable`). CronJob **name
must be `govgraph-refresh`** (alert `GovgraphRefreshStale`).

#### Deployment (web)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: govgraph
      app.kubernetes.io/component: web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: govgraph
        app.kubernetes.io/component: web
    spec:
      automountServiceAccountToken: false
      imagePullSecrets: [{name: nexus-pull}]
      terminationGracePeriodSeconds: 30
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        runAsGroup: 1001
        fsGroup: 1001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          image: registry.home.arpa/govgraph/web  # digest-pinned in the overlay
          # start.mjs empties both cache mounts, then loads server.js, so a restart
          # never serves entries whose in-memory invalidation tags were lost.
          command: ["node", "start.mjs"]
          workingDir: /app
          # resources: apps-deploy apps/govgraph
          ports:
            - containerPort: 3000
              name: http
          envFrom:
            - secretRef:
                name: govgraph
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          # Native preStop sleep. The image has no shell. Cluster is Kubernetes 1.33.
          lifecycle:
            preStop:
              sleep:
                seconds: 5
          volumeMounts:
            - name: next-cache
              mountPath: /app/.next/cache
            - name: route-cache            # ISR output, per the app contract (docs/lab-container.md); never mount over .next/server/app
              mountPath: /app/.next/server/route-cache
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
      volumes:
        - name: next-cache
          emptyDir:
            sizeLimit: 128Mi
        - name: route-cache
          emptyDir:
            # Exceeding a sizeLimit makes the kubelet EVICT the pod (not a failed write).
            # Size is bounded by the route count (entries overwrite per route); take the
            # measured value from the app contract x2, never below 2Gi.
            sizeLimit: 2Gi
```

Container resources, including ephemeral-storage, are in apps-deploy `apps/govgraph`.
The tenant ResourceQuota does not list ephemeral-storage, and the LimitRange max is
cpu and memory only.

#### Service + headless Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  ports:
    - name: http
      port: 3000
      targetPort: http
  selector:
    app.kubernetes.io/name: govgraph
    app.kubernetes.io/component: web
---
apiVersion: v1
kind: Service
metadata:
  name: web-headless
spec:
  clusterIP: None
  # Include NotReady pods: a running pod that briefly fails readiness during the
  # refresh keeps its cache files and in-memory tags; headless DNS would omit it,
  # refresh.mjs would skip it, and it would serve stale HTML once Ready again.
  # (A freshly started pod is safe: start.mjs empties its caches.)
  publishNotReadyAddresses: true
  ports:
    - name: http
      port: 3000
      targetPort: http
  selector:
    app.kubernetes.io/name: govgraph
    app.kubernetes.io/component: web
```

Refresh uses `REVALIDATE_HOST=web-headless` (or `web-headless.<ns>.svc`),
`REVALIDATE_PORT=3000` and `REVALIDATE_SETTLE_MS=10000` so every pod expires its cache
tags twice, with a settle wait between the rounds (in memory; the files under
`.next/cache` and `.next/server/route-cache` stay on disk and are regenerated on the next
request; only `start.mjs` deletes them). Put those three
in the CronJob env; do not put them in OpenBao. The settle value is the program
default; it has to be longer than the longest render, including database latency.

#### CronJob (refresh)

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: govgraph-refresh
spec:
  schedule: "0 4 * * *"
  timeZone: Africa/Lagos
  concurrencyPolicy: Forbid
  suspend: false  # both overlays set true; the prod promotion PR sets false
  jobTemplate:
    spec:
      # Deadline covers persist, two revalidate rounds, the settle, one purge, and the warm.
      activeDeadlineSeconds: 1800
      backoffLimit: 2
      template:
        metadata:
          labels:
            app.kubernetes.io/name: govgraph
            app.kubernetes.io/component: refresh
        spec:
          restartPolicy: Never
          automountServiceAccountToken: false
          imagePullSecrets: [{name: nexus-pull}]
          securityContext:
            runAsNonRoot: true
            runAsUser: 1001
            runAsGroup: 1001
            fsGroup: 1001
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: refresh
              image: registry.home.arpa/govgraph/web  # same digest as web
              command: ["node", "refresh.mjs"]
              workingDir: /app
              # resources: apps-deploy apps/govgraph
              envFrom:
                - secretRef:
                    name: govgraph-refresh
              env:
                - name: REVALIDATE_HOST
                  value: web-headless
                - name: REVALIDATE_PORT
                  value: "3000"
                - name: REVALIDATE_SETTLE_MS
                  value: "10000"
              securityContext:
                readOnlyRootFilesystem: true
                allowPrivilegeEscalation: false
                capabilities:
                  drop: ["ALL"]
              # No volumeMounts. The contract: refresh writes nowhere (no cache, no /tmp).
```

Do not set `WARM_BASE_URL`. `refresh.mjs` does not read it.

Order inside `refresh.mjs`: persist, revalidate every web pod, wait
`REVALIDATE_SETTLE_MS`, revalidate every web pod again, **then** purge Cloudflare
(ADR Rev D condition 2), **then** warm the pods. Purging earlier lets the edge
re-cache stale HTML. Warm-up is not an edge refill and not a GET of the public
hostname. After the purge the job GETs `/ng` and the versioned graph URL found in
that page on **each pod** directly (the pod IPs from the final successful revalidation round; DNS is re-resolved for every round and retry).
That fills pod caches. The Cloudflare edge is filled later by real client misses.
A failed persist, DNS lookup, revalidation round, or purge skips warm-up and fails
the job. A warm-up failure is logged (`pod warmups failed after purge; refresh
succeeded`) and does **not** fail the job, so it does not consume `backoffLimit`.
`restartPolicy: Never` does not restart the pod in place. A failed purge can be
retried only up to that limit, and it cannot be undone.

#### HTTPRoute (hostnames only in apps-deploy)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: govgraph
spec:
  parentRefs:
    - name: public-gateway
      namespace: nginx-gateway
      sectionName: http
  hostnames:
    - "<govgraph-host>"   # staging overlay: <govgraph-staging-host>
  rules:
    - backendRefs:
        - name: web
          port: 3000
```

Cloudflare Access in front of `<govgraph-staging-host>` only. Apex
`<govgraph-host>` stays public.

CI in the GitHub source repo must **build without `DATABASE_URL`** (Rev D condition
4). Pages generate on first request in the cluster.

### 4. Edge rules before DNS (ADR Rev D conditions 1–6)

Do **not** change public DNS until all six are true:

1. **Edge rules live.** Cache rules for HTML and the graph data (cache key ignores
   unknown query strings), Bot Fight Mode, AI-crawler blocking, and one rate-limit
   rule on uncacheable paths.
2. **Refresh ordering.** CronJob revalidates every web pod, waits
   `REVALIDATE_SETTLE_MS`, revalidates again, then purges, then warms each pod's
   `/ng` and versioned graph URL directly. Warm-up failures are logged and do not
   fail the job. Purge token in OpenBao (`CF_API_TOKEN`). The Cloudflare zone holds
   **govgraph hostnames only** — the token's purge is zone-wide, so keep it that
   way: as long as no other app shares the zone, a purge can never drop someone
   else's edge cache.
3. **Split egress.** Web = DNS + TCP 5432/6543 only (the app URL uses the transaction pooler :6543). Refresh = HTTPS + 5432/6543 + web:3000.
   Proven by the NetworkPolicies in this repo.
4. **Build without database credentials.** Image build does not receive
   `DATABASE_URL`.
5. **Tenant quota.** The caps in `k8s/tenants/govgraph/{staging,prod}` are synced on `govgraph-staging` / `govgraph-prod`.
6. **Outside check and alerts.** Outside uptime check (D8). PrometheusRule
   `govgraph-rules` covers the public-path probes (apex + staging — that is where a 5xx
   shows), CronJob no success within 26h (including a CronJob that has never succeeded),
   and web pods not ready. Edge cache-hit ≥90 % and origin-egress daily threshold alerts are
   still owner follow-up (they need Cloudflare analytics, not in-cluster scrapes).

Also configure Cloudflare Tunnel public hostname origin
`http://public-gateway-nginx.nginx-gateway.svc:80` for `<govgraph-host>` and
`<govgraph-staging-host>` ([edge-public.md](edge-public.md)) **before** the DNS
cut-over.

### 5. DNS cut-over

Proxied CNAME of `<govgraph-host>` (and staging) to the existing tunnel, same pattern
as personal-site. Do not point at `.240` or any LAN address. Keep Vercel configured
as the rollback target (D9) until the account is unblocked and a week is green.

### 6. Rollback to Vercel

1. In Cloudflare DNS, point `<govgraph-host>` back at Vercel (or restore the previous
   record). Do not delete the tunnel hostname map until traffic has moved.
2. Leave the lab Deployment running until Vercel is serving; then scale to 0 in
   apps-deploy if you want the quota back.
3. The promoter can keep copying images; admission still requires the lab-signed
   digest if you return.

## Alerts

PrometheusRule `govgraph-rules` (`k8s/platform/monitoring/manifests/govgraph-prometheusrule.yaml`).
promtool tests: `k8s/platform/monitoring/rules/govgraph.test.yaml`.

**Why probes, not a 5xx ratio:** govgraph serves no `/metrics` and nothing scrapes the
NGF data plane (no ServiceMonitor), so an `http_requests_total`-style ratio has no
source. The request-health signal is the public-path blackbox probe — personal-site's
pattern (jobs `govgraph-apex` / `govgraph-staging` in `k8s/platform/monitoring/values.yaml`,
targets file_sd from OpenBao, owner step above). The `http_2xx_public` module only accepts
200, so a 5xx fails the probe; a NetworkPolicy admitting Prometheus to the web pods on
`:3000` is already in the netpol component for the day the app serves `/metrics`.

| Alert | Meaning |
|---|---|
| `GovgraphApexDown` | public-path probe of `<govgraph-host>` failing for 2m (job `govgraph-apex`, expects 200; any 5xx fails it) |
| `GovgraphStagingDown` | public-path probe of `<govgraph-staging-host>` failing for 2m (job `govgraph-staging`, expects 302 behind Cloudflare Access) |
| `GovgraphRefreshStale` | `govgraph-refresh` has not succeeded within 26h — last success older than 26h **or** the CronJob has existed 26h without ever succeeding (`kube_cronjob_created` + `absent()`) |
| `GovgraphProdUnavailable` | Deployment `web` available replicas < 1 for 2m |

Promoter paging is the healthchecks check behind `govgraph-promoter-watchdog-url`,
not Alertmanager ([promoter.md](promoter.md)).
