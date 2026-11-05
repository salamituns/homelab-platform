# Runbook: kube-prometheus-stack (control-plane scrapes)

The chart is Argo CD app `monitoring` (`k8s/platform/apps/monitoring.yaml`),
values in `k8s/platform/monitoring/values.yaml`, extras in
`k8s/platform/monitoring/manifests/`. Grafana login is the out-of-git Secret
`monitoring/grafana-admin`.

## Web UIs (Grafana, Prometheus, Alertmanager) and their exposure

Three UIs are published through the shared Gateway with the lab CA (`*.apps.home.arpa`,
wildcard DNS to `.240` needs no per-host entry):

| UI | URL | Auth |
|---|---|---|
| Grafana | https://grafana.apps.home.arpa | Secret `grafana-admin` |
| Prometheus | https://prometheus.apps.home.arpa | **None** |
| Alertmanager | https://alertmanager.apps.home.arpa | **None** |

`prometheusSpec.externalUrl` / `alertmanagerSpec.externalUrl` are set to those URLs in
`values.yaml` so the links in alert emails (generatorURL, Alertmanager UI) open from a
browser. They are root paths: the chart derives `routePrefix` from the external URL
path, and `/` keeps the default `/` (verified in the 88.3.0 render - the API and UI
endpoints do not move).

**The Prometheus and Alertmanager UIs sit behind oauth2-proxy** (ADR 0016 step 3; runbook
`docs/runbooks/oidc-sso.md`). Prometheus allows Gitea org `homelab`; Alertmanager allows
only `homelab:platform-admins` (the UI can create silences). Inside the cluster the
services stay unauthenticated; netpols now admit oauth2-proxy (and falcosidekick /
argo-rollouts) rather than the Gateway data plane. Break-glass is the admin SSH
port-forward (ADR 0003). Anyone who silences an alert should expect to explain it
in review — silences appear in the Alertmanager UI audit of the alert groups.

## Why kube-proxy / etcd / scheduler / controller-manager monitors are off

On this cluster those four processes bind their metrics ports on **127.0.0.1**
only (verified with `ss` on the nodes: kube-proxy 10249, etcd 2381,
kube-scheduler 10259, kube-controller-manager 10257). Prometheus scrapes the
node IPs, so the targets stay down and the default rules fire
`etcdInsufficientMembers`, `TargetDown`, and `*Unreachable` constantly.

The git values set `kubeProxy` / `kubeEtcd` / `kubeScheduler` /
`kubeControllerManager.enabled: false` and turn off the matching
`defaultRules.rules` (`etcd`, `kubeProxy`, `kubeControllerManager`,
`kubeSchedulerAlerting`, `kubeSchedulerRecording`). That is the low-risk
change: no host edits, no extra bind address on the control plane.

## Alternative: rebind so scrapes work (owner, host change)

Do **not** do this from an agent. It is a kubeadm change on the nodes:

1. On the control-plane, set ExtraArgs so etcd / kube-scheduler /
   kube-controller-manager listen on the node address (or 0.0.0.0) for their
   metrics ports, then `kubeadm init phase control-plane` / restart static
   pods as appropriate for this kubeadm version.
2. kube-proxy: `metricsBindAddress` in the kube-proxy ConfigMap (typically
   `kube-system/kube-proxy`), then roll kube-proxy.
3. Re-enable the four chart components and their default rules in
   `k8s/platform/monitoring/values.yaml` and let Argo sync.

Cost: those ports become reachable from the node IPs (and anything that can
route to them). Leave them loopback-only unless you actually want the alerts.

## Undo

Set the four `enabled` flags and the five `defaultRules.rules` keys back to
`true` in `values.yaml`. The ServiceMonitors and PrometheusRules return on the
next sync; the false alarms return with them until the processes listen off
loopback.

## Cluster certificate expiry (replaces KubeClientCertificateExpiration)

The `KubeClientCertificateExpiration` default rule is disabled (it fires permanently because the daily
operator certificate lives 8 hours by design). Check the long-lived kubeadm certificates instead, every
few months and before 2027-08 (the old admin client cert expires 2027-08-17):

```sh
ssh Master 'sudo kubeadm certs check-expiration'
```

kubeadm renews the control-plane certificates on each `kubeadm upgrade`; renew by hand with
`sudo kubeadm certs renew all` on master (owner step, then restart the static pods).

## Dashboards as code (ADR 0017 PR 2)

Grafana 13.1.3 loads dashboards from ConfigMaps labelled `grafana_dashboard=1` via the
kiwigrid sidecar (`METHOD=WATCH`, `NAMESPACE=ALL`, `FOLDER_ANNOTATION=grafana_folder`).
JSON in git is the source of truth. Admin UI edits are overwritten on the next ConfigMap
WATCH event; Viewers can only look.

**Add or change a dashboard**

1. Put a Grafana JSON file in `k8s/platform/monitoring/dashboards/` with a stable `uid`
   (do not reuse `belleshop-golden-signals`; that ConfigMap lives in belleshop-deploy).
   Datasource UIDs on this cluster: Prometheus `prometheus`, Loki `loki`.
2. List it under `configMapGenerator` in `k8s/platform/monitoring/dashboards/kustomization.yaml`.
   Keep `disableNameSuffixHash: true` and `grafana_folder: Homelab`.
3. Prove every PromQL/LogQL against live Prometheus/Loki (Grafana pod `wget`, as in this
   PR's report) so a panel is not empty after sync.
4. Merge. The monitoring Argo app source `k8s/platform/monitoring/dashboards` (not
   `manifests/`) is what includes the ConfigMaps. After sync, Grafana folder **Homelab**
   shows the dashboard. Sidecar log: `kubectl -n monitoring logs deploy/prometheus-stack-grafana -c grafana-sc-dashboard`.

Dashboards in this repo: **BelleShop overview** (`uid: belleshop-overview`) and
**BelleShop SLO** (`uid: belleshop-slo`). SLO probe panels are empty until the
blackbox Probe CRs scrape. Do not duplicate golden-signals here; see
[`belleshop-slo.md`](belleshop-slo.md) for the scale-to-zero proof.

## Week 8 chaos alerts (ADR 0018)

These ship before the matching drill. Critical goes to the generic `severity=critical`
email route; warnings stay on the root `null` receiver (UI only). Confirmed with
`amtool config routes test` against `k8s/platform/monitoring/alertmanager/alertmanager.check.yaml`.

### HomelabTlsCertExpiringSoon

**Means:** blackbox `probe_ssl_earliest_cert_expiry` for a shop (or debug) HTTPS
probe is under 21 days (warning) or 7 days (critical), `for: 1h`. Today those
probes all see the Gateway wildcard `*.apps.home.arpa` (`notAfter`
2027-01-31T20:38:31Z).

**First check:** which `instance` label. `openssl s_client -servername
belleshop.apps.home.arpa -connect 192.168.1.240:443` (lab root). Do **not**
shorten `nginx-gateway/apps-home-arpa` for a drill — that is the wildcard.
Chaos host only, per ADR 0018 drill 3.

### HomelabCertManagerCertExpiringSoon

**Means:** `certmanager_certificate_expiration_timestamp_seconds` for a
Certificate object is under 21 days (warning) or 7 days (critical), `for: 1h`.
Needs the `cert-manager` ServiceMonitor on controller `:9402` and
`cert-manager-metrics-ingress`. Until that scrapes, the rule cannot fire.

**First check:** `kubectl -n cert-manager get certificate,certificaterequest`.
Prometheus targets for job `cert-manager`. Same wildcard warning as above.

### HomelabDiskCanaryEvicted

**Means:** a pod named `homelab-disk-canary*` is Evicted
(`kube_pod_status_reason` or `kube_pod_container_status_last_terminated_reason`).
Warning only. This is drill 4: emptyDir `sizeLimit`, not a node root fill.
`kubelet_evictions` is not a live metric here.

**First check:** `kubectl get pods -A --field-selector=status.phase=Failed`.
Compare nodefs `%` on all three nodes (`node_filesystem_avail_bytes{mountpoint="/"}`).
If nodefs moved more than ~2 points, abort the drill. Revert the canary git PR.

### HomelabKubeNodeNotReadyFast

**Means:** `up{job="node-exporter"} == 0` for 2 minutes. Critical (email). This
is drill 5: workernode1 VM 107 can take kube-state-metrics with it, so
`KubeNodeNotReady` (`for: 15m`) will not evaluate. Prometheus on workernode2
still sees the dead node-exporter scrape.

**First check:** `qm status 107` on `tuns`. Do not `qm stop`. If this is not a
drill, check the node-exporter DaemonSet pod on that node and whether the
instance is `.89` (wn1), `.84` (wn2) or `.90` (master). Alertmanager itself
lives on wn1 — a real 107 outage will page in Prometheus/Grafana but may not
email until 107 is back.
