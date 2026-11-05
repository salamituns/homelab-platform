# Runbook: BelleShop SLOs (blackbox probes + burn-rate alerts)

Synthetic HTTPS probes through `homelab-gateway` (`192.168.1.240:443`) feed a 99.5%
/ 30-day availability SLO and a 99% latency SLI. This is ADR 0017 PR 3. There are
no real users; the probes **are** the traffic.

| Probe | URL | In SLO? |
|---|---|---|
| `shop-home` | `https://belleshop.apps.home.arpa/` | yes |
| `shop-api` | `https://belleshop.apps.home.arpa/api/healthz` | yes |
| `shop-api-debug` | `https://api-belleshop.apps.home.arpa/healthz` | no (owner decision 4) |

Dashboard: [BelleShop SLO](https://grafana.apps.home.arpa/d/belleshop-slo) (`uid: belleshop-slo`).
Alert emails group by `[alertname, slo, window]` with `repeat_interval: 12h`.

Prometheus retention is **7 days**, so the "error budget remaining" panel uses the
**3d** error ratio against a 30d 0.5% budget. It is an estimate, not a 30d integral.

Loki-node disk: kube-prometheus-stack `node-exporter` rules
`NodeFilesystemSpaceFillingUp` and `NodeFilesystemAlmostOutOfSpace` are **live**
(inactive on 2026-11-04). Do not add a duplicate. After the Loki PVC bind, host `df`
on `workernode1` is still an owner SSH check ([`logs.md`](logs.md)).

## What each alert means

| Alert | Severity | When | First checks |
|---|---|---|---|
| `BelleShopAvailabilityBurnFast` | critical (page) | 14.4× budget on **1h AND 5m** (~7.2% failed probes). A 2-minute blip does not page; ~5 minutes of total failure does. | Probe series, Gateway, backend Rollout |
| `BelleShopAvailabilityBurnMedium` | critical (page) | 6× on **6h AND 30m** | Same; this is a slower burn that still pages |
| `BelleShopAvailabilityBurnSlow` | warning (ticket) | 1× on **3d AND 6h** | Trend, not an outage |
| `BelleShopLatencyBurnFast` | **warning only** | 14.4× on 1h AND 5m against the 99% latency SLI (500 ms home / 300 ms healthz) | Promote to page only after 24 h of `probe_duration_seconds` (owner decision 1) |

`api-belleshop.apps.home.arpa` failing while the two SLO probes are green is a
debug signal, not a page.

## First checks (availability page)

1. Grafana dashboard `belleshop-slo`: which probe is `probe_success=0`.
2. From a machine that trusts the lab root:
   `curl -q --cacert ansible/files/ca/lab-root.crt -o /dev/null -w '%{http_code}\n' https://belleshop.apps.home.arpa/api/healthz`
3. `kubectl -n nginx-gateway get pods,ep -o wide` — data-plane endpoint must stay
   `*:443` (post-DNAT dest for blackbox).
4. `kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus-blackbox-exporter`
   and `kubectl -n monitoring describe probe`.
5. `kubectl -n dev get rollout backend` — Ready replicas. The API is an Argo
   **Rollout**, not a Deployment.
6. Logs: Grafana Explore Loki `{namespace="dev"}`.

A blackhole here is often the NetworkPolicy: blackbox must egress to
`homelab-gateway-nginx:443` (pod IP), not only to `192.168.1.240/32`.

## Drill: prove the page fires (done 2026-11-05)

Cause the outage **through git**, like a real bad deploy. Do not scale with `kubectl`: the `belleshop` app
has `selfHeal: true` AND is itself managed by `platform-root` (also `selfHeal: true`), so pausing the child's
automation is undone by the parent within minutes and the scale is reverted (checked live 2026-11-05). The
workload is `rollout/backend` (Argo Rollouts), not a Deployment.

1. Confirm both SLO probes are `1` (dashboard `belleshop-slo`).
2. PR in `belleshop-deploy`: `base/backend-rollout.yaml` `replicas: 0`. The owner merges it in the Gitea UI
   (branch protection: `homelab-bot` cannot merge in that repo, by design).
3. Wait for the critical email(s). Prepare the restore PR (`replicas: 2`) meanwhile.
4. Owner merges the restore PR. Fast-burn resolves within ~5-8 min of recovery (5m window); Medium-burn about
   30 min later (30m window still holds the outage); the 3d warning stays a while (UI only, no email).

### Recorded run 2026-11-05 (UTC)

| Time | Event | Elapsed |
|---|---|---|
| 00:26:08 | belleshop-deploy #26 merged (backend replicas 0) | 0:00 |
| 00:28:53 | Argo CD synced, backend 0 replicas | +2:45 |
| 00:29:18 | `shop-api` probe `probe_success=0` | +3:10 |
| 00:30:07 | `BelleShopAvailabilityBurnMedium` firing; email received | ~+4 |
| 00:32:13 | `BelleShopAvailabilityBurnFast` firing; Alertmanager -> email | +6:05 |
| 00:35:00 | belleshop-deploy #27 merged (restore) | +8:52 |
| 00:35:53 | backend 2/2 ready, `shop-api` probe back to 1 | +9:45 (recovery 53 s) |
| ~00:43 | Fast-burn resolved email | |

Notes: Medium fired before Fast because the probes had existed only ~20 min, so the 6h/1h windows held only
20 min of data (a new SLO's long windows are not yet long). The `runbook_url` annotation pointed at the
dashboard; fixed to this document after the drill.
