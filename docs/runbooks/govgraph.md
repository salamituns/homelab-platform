# Runbook: govgraph tenant (Phase 2)

Why and what: [ADR 0019](../adr/0019-internal-developer-platform.md) Rev D (Phase 2
hosting) and D1–D9. Second public tenant after `personal-site`. Next.js 16, Postgres
on Supabase, daily refresh CronJob. This repo stays hostname-free; public names are
written here as `<govgraph-host>` / `<govgraph-staging-host>`.

Do not `kubectl apply` from this document until the owner is cutting over. Platform
YAML is in `k8s/tenants/govgraph/`. Workloads (Deployment, Service, headless Service,
CronJob, HTTPRoute) live in **apps-deploy**, not this repo.

## Quota (why these numbers)

`workernode3` is Terraform `4` cores / `8192` MiB (`terraform/proxmox/main.tf`, ADR 0019
D2). **Live allocatable was not queried** (no cluster apply in this change). Typical
kubelet reservation on an 8 Gi node leaves roughly 7–7.5 Gi allocatable after
DaemonSets (Falco, Alloy, node-exporter, kube-network-policies, Flannel, kube-proxy).

The kit default is `requests.cpu: 2` / `requests.memory: 2Gi` **per namespace**. Two
govgraph environments at kit default plus `personal-site` at kit default would
oversubscribe the node before any cache-busting flood.

Caps in the overlays (sum of requests is the scheduler truth):

| Env | pods | requests | limits | LimitRange default / max |
|---|---|---|---|---|
| staging | 6 | 500m / 768Mi | 1 / 2Gi | 250m/512Mi, max 1/768Mi |
| prod | 8 | 1 / 1536Mi | 2 / 3840Mi | 500m/768Mi, max 1/1536Mi |

**Why limits.memory is that size** — a rollout surge of `web` (replicas 1 + surge 1) plus
one refresh job pod must fit in the same namespace:

| Env | web ×2 at the LimitRange **max** | refresh at the LimitRange **default** | limits.memory |
|---|---|---|---|
| staging | 2 × 768Mi = 1536Mi | 512Mi | 1536 + 512 = **2048Mi = 2Gi** |
| prod | 2 × 1536Mi = 3072Mi | 768Mi | 3072 + 768 = **3840Mi** |

(The first draft had 1536Mi / 3Gi: exactly 2 × max with nothing left, so the refresh pod
could not be admitted during a surge.) Requests fit at the LimitRange defaultRequest:
staging 3 × 256Mi = 768Mi, prod 3 × 384Mi = 1152Mi ≤ 1536Mi. That assumes apps-deploy
does **not** set request = limit; if it ever does, raise `requests.memory` to match the
limits line.

Together: **1.5 CPU / 2.25 Gi requests**, **3 CPU / 5.75 Gi limits**. Limits are ceilings,
not reservations — a cache-busting flood can still only consume govgraph's quota, and the
kubelet's node-pressure eviction is the backstop; `personal-site` and DaemonSets keep
their requests. Raise in the overlay if the app needs more; do not remove the quota.

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

Roles: `tenant-govgraph-staging`, `tenant-govgraph-prod`. Policy allows
`secret/data/apps/govgraph/<env>/*` and `secret/data/platform/nexus-pull` only.
Details: [tenant-secrets.md](tenant-secrets.md).

Then write the app keys (never print values; never commit them). One KV object per
env, properties matching `ExternalSecret/govgraph`:

| Key | Used by |
|---|---|
| `DATABASE_URL` | Secret `govgraph` (web) and `govgraph-refresh`, both envs |
| `CRON_SECRET` | Secret `govgraph` (web) and `govgraph-refresh`, both envs |
| `CF_ZONE_ID` | Prod Secret `govgraph-refresh` only |
| `CF_API_TOKEN` | Prod Secret `govgraph-refresh` only |

`CF_API_TOKEN` is a Cloudflare API token with **Zone.Cache Purge** on the govgraph
zone **only** (not account-wide, not DNS edit). Write it on the prod KV object only.

**Staging does not purge.** Staging and prod sit in the same Cloudflare zone, and a
purge clears the whole zone, so a staging refresh would also drop prod's edge cache.
If staging also points at the prod Supabase database, it would write the same
snapshot twice a day. So the staging CronJob ships with `suspend: true`, and the
staging `ExternalSecret/govgraph-refresh` does not reference `CF_ZONE_ID` or
`CF_API_TOKEN` (only `DATABASE_URL` and `CRON_SECRET`, so that Secret syncs without
them). The program still requires the Cloudflare keys before it persists, so a hand
trigger (`kubectl create job --from=cronjob/govgraph-refresh`) fails closed before
the purge. Only prod refreshes on schedule. There is no `WARM_BASE_URL` in either
environment.

Gitea group `govgraph-dev` must exist; the tenant RoleBinding subjects that group.

**Probe targets (monitoring, not tenant paths).** The request-health alerts probe the
public paths, like personal-site's. The two govgraph URLs live in the existing
`monitoring/public-site-probes` KV object (keys `govgraph_apex_url`,
`govgraph_staging_url`) so the SecretStore, ServiceAccount and OpenBao role are reused.
Write them with the raw breakglass mode **before the platform PR merges** — ESO renders
all four target files from that one object, so until both keys exist the probe-targets
ExternalSecret cannot sync; the git bootstrap keeps `[]` for govgraph, so its alerts stay
silent, not wrong:

```sh
scripts/openbao-breakglass.sh root-run -- bao kv patch secret/monitoring/public-site-probes \
  govgraph_apex_url='https://<govgraph-host>/' \
  govgraph_staging_url='https://<govgraph-staging-host>/'
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
staging PR. Copy-paste shapes below. Replace `<govgraph-host>` /
`<govgraph-staging-host>`. Image digest comes from the promoter, not from git in
this repo.

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
          # Explicit: Kyverno require-requests-limits checks the pod template, which a
          # LimitRange does not fill. Prod values; staging overlay: requests 150m/256Mi,
          # limits.memory 768Mi. Fits the quota table above with a rollout surge plus refresh
          # (prod requests 2 x (300m, 384Mi) + (100m, 384Mi) = 700m / 1152Mi <= 1 / 1536Mi).
          resources:
            requests: { cpu: 300m, memory: 384Mi, ephemeral-storage: 512Mi }
            limits: { memory: 1536Mi, ephemeral-storage: 3Gi }
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

Web ephemeral-storage is request 512Mi and limit 3Gi: the 128Mi fetch cache, the
2Gi route cache, and logs. Refresh is request 64Mi and limit 256Mi (no writable
mount; the limit is log scratch). The tenant ResourceQuota has no ephemeral-storage
key, so those requests are not quota. The LimitRange max is cpu and memory only, so
it does not cap these.

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
  suspend: false  # staging overlay: true — staging stays suspended (step 1)
  jobTemplate:
    spec:
      # 1800s covers persist, two revalidate rounds, the 10s settle, one purge,
      # and the per-pod warm. backoffLimit 2 stops OnFailure from re-purging forever.
      activeDeadlineSeconds: 1800
      backoffLimit: 2
      template:
        metadata:
          labels:
            app.kubernetes.io/name: govgraph
            app.kubernetes.io/component: refresh
        spec:
          restartPolicy: OnFailure
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
              resources:                  # prod; staging overlay: 100m/256Mi, limit 512Mi
                requests: { cpu: 100m, memory: 384Mi, ephemeral-storage: 64Mi }
                limits: { memory: 768Mi, ephemeral-storage: 256Mi }
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
that page on **each pod** directly (the A records captured from `web-headless`).
That fills pod caches. The Cloudflare edge is filled later by real client misses.
A failed persist, DNS lookup, revalidation round, or purge skips warm-up and fails
the job. A warm-up failure is logged (`pod warmups failed after purge; refresh
succeeded`) and does **not** fail the job, so `restartPolicy: OnFailure` cannot
re-run persist and purge. It also cannot undo the purge.

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
5. **Tenant quota.** Caps above are synced on `govgraph-staging` / `govgraph-prod`.
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
