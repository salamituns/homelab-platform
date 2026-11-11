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
| staging | 6 | 500m / 768Mi | 1 / 1536Mi | 250m/512Mi, max 1/768Mi |
| prod | 8 | 1 / 1536Mi | 2 / 3Gi | 500m/768Mi, max 1/1536Mi |

Together: **1.5 CPU / 2.25 Gi requests**, **3 CPU / 4.5 Gi limits**. A cache-busting
flood can only consume govgraph's quota; `personal-site` and DaemonSets keep their
share. Raise in the overlay if the app needs more; do not remove the quota.

## Split egress

kube-network-policies v1.1.2 is **post-DNAT** and cannot match a hostname, so
Supabase is an IP-wide TCP `:5432` allow with RFC1918 except'd (LAN Postgres stays
closed). Web pods have no `:443`. Refresh pods get `:443` except RFC1918 (and
therefore except the cluster pod/Service ranges under `10.0.0.0/8`), `:5432` the same
way, and TCP 3000 to web pods. Public-gateway ingress is the kit policy, patched to
`component=web` port 3000, plus refresh→web `:3000`.

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
| `DATABASE_URL` | Secret `govgraph` (web) and `govgraph-refresh` |
| `CRON_SECRET` | Secret `govgraph` (web) and `govgraph-refresh` |
| `CF_ZONE_ID` | Secret `govgraph-refresh` only |
| `CF_API_TOKEN` | Secret `govgraph-refresh` only |

`CF_API_TOKEN` is a Cloudflare API token with **Zone.Cache Purge** on the govgraph
zone **only** (not account-wide, not DNS edit). Staging and prod may share a token if
they share a zone.

**Staging does not purge.** Staging and prod sit in the same Cloudflare zone, and a
purge clears the whole zone, so a staging refresh would also drop prod's edge cache.
If staging also points at the prod Supabase database, it would write the same
snapshot twice a day. So the staging CronJob ships with `suspend: true` and no `CF_*` keys in
`secret/apps/govgraph/staging`; trigger it by hand (`kubectl create job --from=cronjob/...`)
when testing a refresh, and expect it to fail at the purge step. Only prod refreshes
on schedule.

Gitea group `govgraph-dev` must exist; the tenant RoleBinding subjects that group.

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
Re-run `playbooks/jenkins.yml` after the files exist.

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
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        fsGroup: 1001
      containers:
        - name: web
          image: registry.home.arpa/govgraph/web  # digest-pinned in the overlay
          ports:
            - containerPort: 3000
              name: http
          envFrom:
            - secretRef:
                name: govgraph
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
          volumeMounts:
            - name: next-cache
              mountPath: /app/.next/cache
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
          emptyDir: {}
```

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
  ports:
    - name: http
      port: 3000
      targetPort: http
  selector:
    app.kubernetes.io/name: govgraph
    app.kubernetes.io/component: web
```

Refresh uses `REVALIDATE_HOST=web-headless` (or `web-headless.<ns>.svc`) and
`REVALIDATE_PORT=3000` so every pod's `emptyDir` ISR cache is busted. Put those two
in the CronJob env; do not put them in OpenBao.

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
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app.kubernetes.io/name: govgraph
            app.kubernetes.io/component: refresh
        spec:
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            runAsUser: 1001
            fsGroup: 1001
          containers:
            - name: refresh
              image: registry.home.arpa/govgraph/web  # same digest as web
              command: ["node", "refresh.mjs"]
              envFrom:
                - secretRef:
                    name: govgraph-refresh
              env:
                - name: REVALIDATE_HOST
                  value: web-headless
                - name: REVALIDATE_PORT
                  value: "3000"
              securityContext:
                readOnlyRootFilesystem: true
                allowPrivilegeEscalation: false
```

Order inside `refresh.mjs`: revalidate every web pod, **then** purge Cloudflare
(ADR Rev D condition 2). Purging first lets the edge re-cache stale HTML.

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
2. **Refresh ordering.** CronJob revalidates every web pod, then purges. Purge token
   in OpenBao (`CF_API_TOKEN`).
3. **Split egress.** Web = DNS + TCP 5432 only. Refresh = HTTPS + 5432 + web:3000.
   Proven by the NetworkPolicies in this repo.
4. **Build without database credentials.** Image build does not receive
   `DATABASE_URL`.
5. **Tenant quota.** Caps above are synced on `govgraph-staging` / `govgraph-prod`.
6. **Outside check and alerts.** Outside uptime check (D8). PrometheusRule
   `govgraph-rules` covers 5xx ratio, CronJob last success >26 h, and web pods not
   ready. Edge cache-hit ≥90 % and origin-egress daily threshold alerts are still
   owner follow-up (they need Cloudflare analytics, not in-cluster scrapes).

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

| Alert | Meaning |
|---|---|
| `GovgraphProd5xxRatioHigh` | >5 % 5xx in `govgraph-prod` for 10m (`http_requests_total`; silent until a ServiceMonitor exists) |
| `GovgraphRefreshStale` | `govgraph-refresh` last success older than 26h |
| `GovgraphProdUnavailable` | Deployment `web` available replicas < 1 for 2m |

Promoter paging is the healthchecks check behind `govgraph-promoter-watchdog-url`,
not Alertmanager ([promoter.md](promoter.md)).
