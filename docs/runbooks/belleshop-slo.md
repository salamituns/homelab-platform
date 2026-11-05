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

## ROADMAP proof (owner, after this PR is synced)

The ROADMAP tick is an email that fired because the API was down, then a resolve.
**Do not** `kubectl -n dev scale deploy/backend`: that object does not exist
(live 2026-11-04: `rollout.argoproj.io/backend`, `deployment.apps/frontend` only).

**Do not** scale while Argo CD `belleshop` has `syncPolicy.automated.selfHeal: true`
(live). Git says 2 replicas; selfHeal restores them in seconds and the fast-burn
never fills a 5m window.

Procedure:

1. Confirm both SLO probes are `1` and the dashboard is green.
2. Pause selfHeal (keeps `syncOptions`; only clears automation):

   ```sh
   kubectl -n argocd patch app belleshop --type merge \
     -p '{"spec":{"syncPolicy":{"automated":null}}}'
   ```

3. Scale the Rollout, not a Deployment:

   ```sh
   kubectl -n dev scale rollout/backend --replicas=0
   ```

   Frontend stays up. `shop-home` may still be 200; `shop-api` fails at the Gateway.
   The SLI is the **average** of the two probes, so availability drops to ~50% with
   only the API down — that is **well above** the 7.2% fast-burn threshold, so the
   page still fires.

4. Wait 5–10 minutes. Capture: Grafana `belleshop-slo`, the
   `BelleShopAvailabilityBurnFast` email, Prometheus alert.

5. Restore and re-enable selfHeal:

   ```sh
   kubectl -n dev scale rollout/backend --replicas=2
   kubectl -n argocd patch app belleshop --type merge \
     -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
   ```

6. Confirm the resolve email and probes back at `1`. Record timestamps. That is
   the interview artefact.

Do not leave `automated: null` or replicas at 0.
