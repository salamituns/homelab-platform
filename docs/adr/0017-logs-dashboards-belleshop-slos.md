# ADR 0017: Loki logs, dashboards as code, and BelleShop SLOs

- Status: Accepted (owner, 2026-11-04, PR #56), with the owner decisions below.
- Date: 2026-11-04
- Owner: owner
- Last reviewed: 4 Nov 2026
- Next review: when the first rollout PR (Loki + Alloy) merges

## Revision history

| Rev | Date | Change |
|---|---|---|
| A | 4 Nov 2026 | Initial proposal from live cluster facts |

## Scope

In scope: a Loki log store on the existing cluster, Grafana dashboards loaded from git through the sidecar
already running, and availability plus p95-latency SLOs for BelleShop's real Gateway paths, with burn-rate
alerts on the existing Alertmanager email route.

Out of scope (and where it lives instead):

- Kubernetes API-server audit logs — needs an apiserver audit policy on the control plane, not a Grafana
  datasource. Not this week.
- Falco events in Loki — Falco already pages over email ([ADR 0015](0015-network-policy-and-platform-hardening.md)
  section D; [docs/runbooks/falco-alerts.md](../runbooks/falco-alerts.md)). Optional later scrape of Falco stdout.
- Node-loss, disk-full, expired-cert, or leaked-secret drills — Week 8.

## Context

Week 7 of the [ROADMAP](../../ROADMAP.md) still has two open items after OIDC ([ADR 0016](0016-oidc-sso-admin-uis-gitea.md)):
Loki plus dashboards as code, and BelleShop SLOs with burn-rate alerts. The proof is a dashboard plus an alert
that fired for a real reason.

BelleShop in `dev` (frontend + API + MySQL) is a practice app run as if it were production. It has **no real
users**, so availability and latency SLOs cannot wait for organic traffic. Synthetic probes must hit the same
HTTPS paths a browser uses, through NGINX Gateway Fabric on `192.168.1.240`.

This ADR is design only. Chart versions, image digests and exact PromQL are pinned at rollout the same way
oauth2-proxy was pinned in ADR 0016.

Verified on 2026-11-04 (read-only: `ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf …'`;
no Docker, kind, or Mac-side containers):

| Area | Current state | Why it matters | Command |
|---|---|---|---|
| Storage class | Only `local-path` (rancher.io/local-path), default, `WaitForFirstConsumer`, **no** volume expansion | Loki PVC is node-local, size is final at bind, same as Prometheus | `kubectl get sc,pvc -A` |
| Existing PVCs | `monitoring` Prometheus 5Gi (bound), Alertmanager 2Gi; `dev` MySQL 5Gi | Workers already hold the disks that matter; do not add a large volume on the master | same |
| Master disk | `/` ext4 40G, 22G used, **16G free** (58%) | A 10Gi Loki volume on the master would consume most of the remaining root filesystem | `df -hT /` |
| Node allocatable | Each node 2 CPU, ~3907Mi memory. Ephemeral-storage: master ~35Gi, workers ~70.6Gi | Memory budget is the tight constraint, not worker disk | `kubectl get nodes -o custom-columns=…allocatable…` |
| Requests vs allocatable | master 1050m/526Mi (52%/13%); workernode1 1020m/1722Mi (51%/45%, limits 78% mem); workernode2 875m/1380Mi (43%/36%, limits 88% mem) | Loki SingleBinary must land on a worker. Alloy per node must stay small so wn2 limits do not OOM | `kubectl describe nodes` (Allocated resources) |
| Loki / Alloy / Promtail / blackbox | none (no Deploy/DS/STS/SVC matching those names) | Greenfield; no Promtail to migrate | `kubectl get deploy,ds,sts,svc -A \| grep -Ei 'loki\|alloy\|promtail\|blackbox'` |
| Grafana | chart kube-prometheus-stack 88.3.0, image `grafana/grafana:13.1.3`, SSO per ADR 0016 (`role_attribute_path` Admin vs Viewer) | Provisioned dashboards are visible to both roles; UI edits are not the source of truth | `k8s/platform/monitoring/values.yaml`; live deploy |
| Dashboard sidecar | container `grafana-sc-dashboard`, `quay.io/kiwigrid/k8s-sidecar:2.10.1`; `LABEL=grafana_dashboard` `LABEL_VALUE=1` `FOLDER=/tmp/dashboards` `METHOD=WATCH` `NAMESPACE=ALL` | Any namespace can ship a labelled ConfigMap; WATCH overwrites files when the CM changes | live deploy env |
| Datasource sidecar | `grafana-sc-datasources`, same image; `LABEL=grafana_datasource` `FOLDER=/etc/grafana/provisioning/datasources` `METHOD=WATCH`; **no** `NAMESPACE=ALL` (defaults to the Grafana namespace) | The Loki datasource ConfigMap must live in `monitoring` | live deploy env |
| Existing dashboard | ConfigMap `monitoring/grafana-dashboard-golden-signals`, label `grafana_dashboard=1`, Argo tracking-id `belleshop:…` | First BelleShop dashboard already exists in **belleshop-deploy**, not this repo. Queries are global `http_requests_total` / `http_request_duration_seconds_*` (no `job="backend"`), so they mix Grafana/Prometheus HTTP metrics | `kubectl get cm -A -l grafana_dashboard=1` |
| Probe CRD | `probes.monitoring.coreos.com` kind `Probe` group `monitoring.coreos.com` version `v1`. **Zero** Probe objects | prometheus-operator already understands blackbox Probe CRs | `kubectl get crd probes.monitoring.coreos.com`; `kubectl get probe -A` |
| App metrics | `up{job="backend",namespace="dev"}` = 1 on two pods. Names: `http_requests_total`, `http_request_duration_seconds_bucket`. Handlers include `/healthz`, `/metrics`, `/token`, `/register`, `/protected` | App histograms exist and are scraped (ServiceMonitor `dev/belleshop-backend-monitor`, 10s, `/metrics`). They measure **in-process** time, not the Gateway path | Grafana pod `wget` Prometheus `/api/v1/query` |
| User HTTPS paths | `belleshop.apps.home.arpa` `/` → frontend:3000; `/api` → backend:8000 with `ReplacePrefixMatch` `/`; `api-belleshop.apps.home.arpa` `/` → backend:8000. TLS at the Gateway VIP `.240` | Synthetic probes must use these hosts, not ClusterIP | `kubectl -n dev get httproute … -o json` |
| NGF metrics | Data-plane Service `homelab-gateway-nginx` 80/443 on `.240`. Control-plane Service `nginx-gateway` **9113**. No ServiceMonitor matching nginx | 9113 is the NGF control-plane metrics port, not a user-path latency histogram we can SLO on today | `kubectl -n nginx-gateway get svc` |
| Monitoring netpol | default-deny; `monitoring-intra-metrics` allows 3000, 8080, 9090, 9093, 10250 only — **no 3100**. `monitoring-api-egress` is `podSelector: {}` to `192.168.1.90:6443`. Prometheus scrape egress already allows `10.244.0.0/16` for pod targets | Loki 3100 and Alloy's metrics port will blackhole until intra-metrics (and Grafana→Loki) gain those ports. Alloy still needs DNS (already covered) + API (already covered) + Loki 3100 | `k8s/platform/monitoring/manifests/netpol-allow.yaml` |
| Alertmanager | Live root route: `receiver: "null"`, `group_by: [namespace]`, `group_wait: 30s`, `group_interval: 5m`, `repeat_interval: 12h`, Watchdog → null. Week 6 Falco flood: one rule mailed ~60 times until `repeat_interval: 24h` and `group_by: [rule, k8s_ns_name]` | SLO mail must inherit a long repeat and group by SLO+window, not by every failing probe | live AM secret (redacted); `docs/runbooks/falco-alerts.md` |
| Worker `df` over SSH | `ssh workernodeN` as the usual admin user is Permission denied | Disk proof for workers is kubelet `ephemeral-storage` allocatable (~70Gi each), not a host `df` | attempted SSH; `kubectl get nodes` |

Worker host `df` was **not** verified. Do not treat 70Gi allocatable as "70Gi free on disk"; it is the kubelet
cap. After the Loki PVC binds, `kubectl get pvc,pv` plus `df` on the chosen worker (owner SSH) is a rollout check.

## Options considered

### Log store

| Option | For | Against |
|---|---|---|
| **Loki SingleBinary, grafana/loki chart, filesystem on `local-path` (chosen)** | Native Grafana datasource; matches the Grafana 13.1.3 already running; one STS + PVC; 7d retention can match Prometheus | No object store; volume dies with the worker (same as Prometheus today, ADR 0008 already recorded that) |
| Loki SimpleScalable / distributed | Headroom later | Three or more components and object storage this lab does not have |
| ELK / OpenSearch | Familiar search UI | Heap on a 4Gi worker would compete with Prometheus (wn2 memory limits already 88%) |
| VictoriaLogs | Light, PromQL-ish | Extra Grafana plugin; this Grafana already speaks Loki natively |

### Collector

| Option | For | Against |
|---|---|---|
| **Grafana Alloy DaemonSet (chosen)** | Promtail is **EOL as of 2 Mar 2026** ([Grafana Loki docs](https://grafana.com/docs/loki/latest/send-data/promtail/)); Alloy is the supported replacement; one agent for logs now and optional metrics later | New config language (River / Alloy syntax) |
| Promtail DaemonSet | Config many people still paste | EOL; no security updates |
| sidecar per pod | Isolation | Every app manifest grows; BelleShop is not the only namespace we want logs from |

### Dashboards as code

| Option | For | Against |
|---|---|---|
| **Existing kiwigrid sidecar + ConfigMaps labelled `grafana_dashboard=1` (chosen)** | Already live, `NAMESPACE=ALL`, METHOD=WATCH; belleshop-deploy already uses it | JSON in git is verbose; UI edits do not stick |
| Grafana provisioning files in the Grafana PVC | None | Sidecar already owns `/tmp/dashboards`; a second loader fights WATCH |
| Grafana Terraform / grizzly API | Nice diffs | Another credential and a write path into Grafana we do not need |

### Synthetic traffic

| Option | For | Against |
|---|---|---|
| **blackbox_exporter + Probe CRD (chosen)** | CRD already on the cluster; operator-native scrape; `probe_success` and `probe_duration_seconds` are the textbook SLO events; one probe per user URL | TLS must trust the lab CA; egress to `.240:443` needs a netpol |
| k6 (or similar) Deployment | Rich scenarios, logins | Extra runtime; no users to log in as; overkill for "is the shop up" |
| CronJob `curl` | Tiny | Sparse samples; p95 over 15s gaps is noise; no Probe CRD, extra scrape glue |

### SLO rule generators

| Option | For | Against |
|---|---|---|
| **Hand-written PrometheusRules (chosen)** | kube-prometheus-stack already ships kube-apiserver multi-window burn rules; we can copy that shape; no extra controller | Easy to get window math wrong — review in the PR |
| Sloth | Generates the four-window set | Another controller and CRD for two SLOs |
| Pyrra | Grafana-friendly SLO UI | Same cost; Grafana SSO Viewers do not need a second SLO product |

## Decisions

1. **Loki in `monitoring`, grafana/loki chart, `deploymentMode: SingleBinary`, filesystem on a `local-path` PVC
   of 10Gi, retention 7d (168h).** Pin chart and image digest at rollout. Schedule it on a **worker**
   (`WaitForFirstConsumer` plus a node affinity / tolerate-workers-only if the scheduler otherwise picks the
   master). Requests on the order of 100m CPU / 256Mi memory, limits 500m / 512Mi — small enough that wn1
   (45% requested memory) can take it. Do **not** put the PVC on the master (16G free on a 40G root).

   **Collector: Grafana Alloy as a DaemonSet** in `monitoring`, not Promtail. Collect Kubernetes pod logs
   (`loki.source.kubernetes` / equivalent) from every namespace; drop nothing on day one (10Gi / 7d is the cap).
   Alloy requests ~50m CPU / 64Mi, limits 100m / 128Mi per node, including the master (CPU 52% requested — keep
   Alloy tiny, no extra scrape pipelines).

   **Grafana datasource as code:** ConfigMap in `monitoring` with label `grafana_datasource: "1"` (the datasource
   sidecar does not search other namespaces). Type `loki`, URL the in-cluster Loki service on port 3100, uid
   `loki`.

   **NetworkPolicy (ADR 0015 lessons):**
   - Add TCP **3100** (Loki) and Alloy's metrics port (chart default, commonly 12345 — confirm at rollout) to
     `monitoring-intra-metrics` ingress **and** egress. Grafana queries Loki on 3100; Prometheus scrapes both.
   - Alloy already matches `monitoring-api-egress` (`podSelector: {}` → `192.168.1.90:6443`) and the existing
     DNS egress. Add an explicit Alloy → Loki 3100 allow if you split Alloy out of `podSelector: {}` later;
     with intra-metrics covering 3100, same-namespace push works.
   - Alloy needs `hostPath` of `/var/log/pods` (and the chart's kubelet pod-logs path). That is a filesystem
     read, not a new netpol. Do not give Alloy hostNetwork.
   - Blackbox (decision 3) needs its own egress to `192.168.1.240/32:443` plus DNS; Prometheus already scrapes
     pod CIDR without ports.

   **Falco / k8s audit:** out of scope for the first PRs (see Scope). Falco can join Loki later by scraping
   its stdout; that is a follow-up, not a blocker.

2. **Dashboards live under `k8s/platform/monitoring/dashboards/` as JSON, generated into ConfigMaps with
   `grafana_dashboard: "1"`.** Do not add a second Grafana loader. `searchNamespace: ALL` already sees
   ConfigMaps in `monitoring` and in `dev`. Include the new files from the monitoring app's kustomization /
   source path (ADR 0015 lesson 7).

   **First dashboard in this repo:** `belleshop-slo.json` — probe success, probe p95, error budget / burn, and
   a Loki panel for `backend` pods in `dev`. Leave the existing golden-signals ConfigMap in belleshop-deploy
   (ADR 0008: it is an app object). A follow-up in that repo should narrow its PromQL to `job="backend"`
   (and `namespace="dev"`): live queries are global and therefore mix Grafana and Prometheus HTTP metrics
   with BelleShop.

   **SSO interaction (ADR 0016):** `homelab:platform-admins` → Grafana **Admin**, other `homelab` members →
   **Viewer**. Provisioned dashboards are visible to both. Viewer cannot persist UI edits. Admin can edit in
   the UI, but sidecar `METHOD=WATCH` rewrites `/tmp/dashboards` whenever the ConfigMap moves, so git remains
   the source of truth. Explore / Drilldown still works for Admin.

3. **SLOs are synthetic, through the Gateway, with blackbox_exporter + Probe CRs.**

   Probes (HTTPS, module `http_2xx`, TLS verify against the **lab CA**, interval 15s):

   | Probe | URL | Why |
   |---|---|---|
   | shop-home | `https://belleshop.apps.home.arpa/` | Frontend user path |
   | shop-api | `https://belleshop.apps.home.arpa/api/healthz` | Same host users see; HTTPRoute strips `/api` → backend `/healthz` |

   Optional third probe `https://api-belleshop.apps.home.arpa/healthz` is the dedicated API host; do not SLO it
   separately unless the first two disagree (it skips the prefix rewrite).

   **Latency source for the SLO:** `probe_duration_seconds` (and `probe_success`). That includes DNS, TCP, TLS
   and the Gateway hop — the number a user would feel. App `http_request_duration_seconds` stays on the
   golden-signals / SLO dashboard as **in-process** latency. NGF `:9113` is unused until someone adds a
   ServiceMonitor; it is not a user-path histogram today.

   **Targets (starting point; change only with a new ADR revision):**

   | SLI | Good events | Target | Window |
   |---|---|---|---|
   | Availability | `probe_success == 1` on shop-home and shop-api | 99.5% | 30d |
   | Latency | successful probe **and** `probe_duration_seconds < 0.5` (home) / `< 0.3` (api healthz) | 99% of good probes | 30d |

   99.5% / 30d is 3.6 hours of downtime budget. Homepage p95 at 300ms is likely too tight once TLS and the SPA
   are in the probe; 500ms home / 300ms healthz is the split. Confirm both against a quiet 24h of
   `probe_duration_seconds` before paging on latency (open question below).

   **Alerts:** hand-written `PrometheusRule` objects, Google SRE multi-window multi-burn-rate, same shape as
   the kube-apiserver burn rules already in kube-prometheus-stack. Page (severity `critical`, existing email
   receiver) on fast burn; ticket-style (severity `warning`, same receiver, long repeat) on slow burn.

   Suggested page pair for a 30d 99.5% SLO (error budget 0.5%):

   | Window | Budget burned | Approx. burn rate | For |
   |---|---|---|---|
   | 1h (short 5m) | 2% | 14.4× | page |
   | 6h (short 30m) | 5% | 6× | page |
   | 3d (short 6h) | 10% | 1× | warning |

   **Email path:** a child route **before** the Falco route, matchers `slo=~"belleshop-.*"`,
   `group_by: [alertname, slo, window]`, `group_interval: 5m`, **`repeat_interval: 12h`** (inherit root if the
   child omits it — do not set 1h). Never group by `instance` or `pod`. The Week 6 Falco flood was per-event
   mail until grouping + 24h repeat; SLO probes fire every 15s and would be worse without this.

4. **ROADMAP proof: scale the BelleShop API to zero, do not kill a node.** Week 8 owns node-loss and disk-full.
   Procedure (owner, after the SLO PR is live):

   1. Confirm both probes `probe_success == 1` and the SLO dashboard is green.
   2. `kubectl -n dev scale deploy/backend --replicas=0` (and the canary if it is serving). Frontend stays up;
      `shop-api` fails at the Gateway.
   3. Wait until the **1h fast-burn** alert fires and email arrives (minutes at 14.4× once the 5m window is
      all failures). Capture the Grafana dashboard (failed probes + burn) and the mail.
   4. Scale back to 2. Probes recover; the alert resolves. Do not leave replicas at 0.
   5. Record timestamps in the rollout runbook. That is the interview artefact.

   A bad Argo Rollouts deploy is a valid alternative if a canary already fails `/healthz`; scaling to zero is
   the deterministic path.

5. **Every e2e check runs on the homelab, in a throwaway namespace, never on the Mac.** No Docker Desktop, kind,
   or extra containers on the 8Gi laptop. Suggested namespace `obs-proof` (delete at the end of the PR).

   | Rollout PR | Must prove before handover |
   |---|---|
   | Loki + Alloy + netpol + datasource | From the Grafana pod (or a Job in `obs-proof`): Loki query returns lines from a throwaway pod **and** from `dev/backend`. Grafana UI shows datasource `loki`. Alloy and Loki pods Ready; `kubectl describe pvc` bound on a **worker**. Rollback: revert, PVC deleted or retained empty. |
   | Dashboards | ConfigMap `grafana-dashboard-belleshop-slo` exists; Grafana lists "BelleShop SLO" for a Viewer login. Sidecar log shows WATCH of that CM. |
   | blackbox + Probes + netpol | `probe_success` for both URLs is 1 in Prometheus. A deliberate wrong path returns 0. Blackbox pod can `openssl s_client` to `.240:443` with the lab CA (netpol + trust). |
   | PrometheusRules + AM route | `promtool` / operator accepts the rule file. Firing test: see decision 4. Email is one thread per `alertname,slo,window`, not one per scrape. |
   | Proof (ROADMAP) | Dashboard screenshot + alert that fired because backend replicas were 0, then resolved. |

6. **Rollout is four (plus proof) small PRs**, each reversible by git revert + Argo sync. Pin versions in the
   first PR like oauth2-proxy. Order:

   1. Loki SingleBinary + PVC + Alloy DaemonSet + netpol 3100/Alloy + Loki datasource ConfigMap.
   2. `k8s/platform/monitoring/dashboards/` + BelleShop SLO dashboard ConfigMap.
   3. blackbox-exporter chart + lab-CA volume + two Probe CRs + blackbox egress netpol to `.240:443`.
   4. PrometheusRules + Alertmanager child route.
   5. Owner-run proof (decision 4); tick the ROADMAP proof line.


## Owner decisions (2026-11-04, on acceptance)

1. **Latency alerts start as `severity: warning`** (no email page) and are promoted after 24 h of real
   `probe_duration_seconds` data justify the 500 ms / 300 ms thresholds. Availability burn-rate alerts page from day one.
2. **Alloy collects every namespace except `kube-system`** (noise vs the 10Gi / 7d Loki volume).
3. **Disk check after the Loki PVC binds:** host `df` on the node that holds it, recorded in the runbook.
4. **`api-belleshop.apps.home.arpa` gets a debug-only probe** (no SLO): users enter through `belleshop.apps.home.arpa`.

## Consequences

- `monitoring` gains a StatefulSet, a DaemonSet, a PVC and (later) blackbox. Worker memory requests rise by
  roughly 256Mi (Loki) + 64Mi (Alloy) on the Loki node and 64Mi Alloy on the others. Stay under the 75% request
  comfort line used in [ADR 0013](0013-gateway-api.md); if wn1 cannot fit Loki, place it on wn2 and drop
  Loki limits before dropping Prometheus retention.
- Logs and Prometheus TSDB are both node-local. A Week 8 worker loss loses 7d of logs on that node the same
  way it loses Prometheus history (ADR 0008). That is accepted until there is object storage.
- Grafana Viewer (SSO) sees the new dashboards without extra RBAC. Admin UI saves are decorative.
- Alerting gains two SLO names. If the child route is listed **after** a catch-all email route, grouping will
  not apply — put it next to the existing `critical` / Falco children, before any broad matcher.
- Blackbox depends on CoreDNS `home.arpa`, the Gateway VIP, and the lab CA. Those already exist; the new
  failure mode is "probe fail because netpol dropped `.240:443`", which the PR-3 proof must catch.

## Not now

- Object storage for Loki (S3/Seaweed). Filesystem is enough for 7d / 10Gi.
- Scraping NGF `:9113` or adding a ServiceMonitor for the data plane. Revisit if we want per-route RPS.
- Falco or apiserver audit in Loki.
- Moving `grafana-dashboard-golden-signals` out of belleshop-deploy.
- Sloth, Pyrra, k6, ELK, VictoriaLogs, Promtail.
- Latency SLO paging before 24h of probe samples exist (ship the rule as `warning` first if needed).

## Open questions

1. Is 500ms (home) / 300ms (healthz) the latency good-event threshold, or should both wait on a day of
   `probe_duration_seconds` before we page?
2. Should Alloy skip `kube-system` to save the 10Gi PVC, or keep "everything" for teaching?
3. Owner SSH to workers for a real `df` after PVC bind — confirm 10Gi does not starve the node that already
   holds Prometheus or MySQL.
4. Exact Alloy metrics port and Loki chart values (`singleBinary.replicas: 1`, gateway enabled or Grafana
   talking to the backend Service) — pin from `helm show values` at rollout, not from this document.
