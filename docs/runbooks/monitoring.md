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

## Public personal-site edge (Phase 1 follow-up)

PrometheusRule `public-edge-rules` plus cloudflared ServiceMonitor, public-path
blackbox jobs (`public-site-apex` / `public-site-staging`), and OpenBao
`root-run public-site-probes`. Runbook: [public-site-alerts.md](public-site-alerts.md).
Prometheus has **no** internet egress; only blackbox_exporter is allowed TCP 443
with RFC1918 except'd.

## Govgraph tenant (Phase 2)

PrometheusRule `govgraph-rules`: public-path probe failures (jobs `govgraph-apex` /
`govgraph-staging`, file_sd targets like personal-site's — govgraph serves no `/metrics`,
so a probe is where a 5xx shows), CronJob `govgraph-refresh` with no success within 26h
(including never-succeeded), Deployment `web` available replicas. Runbook:
[govgraph.md](govgraph.md). Cache-hit / origin-egress alerts from ADR 0019 Rev D
condition 6 are not in this rule file (they need Cloudflare analytics).

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

Dashboards in this repo: **BelleShop overview** (`uid: belleshop-overview`),
**BelleShop SLO** (`uid: belleshop-slo`), and **Lynis** (`uid: lynis-hardening`).
SLO probe panels are empty until the blackbox Probe CRs scrape. Lynis panels are
empty until the Ansible role has written `/var/lib/node_exporter/textfile/lynis.prom`
and the node-exporter textfile collector is synced. Do not duplicate golden-signals
here; see [`belleshop-slo.md`](belleshop-slo.md) for the scale-to-zero proof.

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
instance is `.89` (wn1), `.84` (wn2) or `.90` (master). After the HA follow-up
(`fu-alertmanager-ha`), one Alertmanager replica should still be on wn1 and
the other on wn2; email should survive a 107 loss. The Alertmanager **UI**
still goes through `oauth2-proxy-alertmanager` (one pod) — that gate can die
with wn1 even when email works.

## Alertmanager HA (drill 5 follow-up)

Two STS replicas, **hard** `podAntiAffinity` on `kubernetes.io/hostname`, each
with its own local-path PVC from the existing `volumeClaimTemplate`. Replica
`-0` keeps `pvc-...-alertmanager-0` on workernode1; `-1` is a new 2 Gi claim
on the other worker. The operator turns on gossip (`--cluster.listen-address=:9094`,
`--cluster.peer` for both ordinals) when `replicas > 1`. Prometheus already
discovers every ready endpoint of `prometheus-stack-kube-prom-alertmanager`
(`kubernetes_sd` role `endpoints`). Gossip needs TCP+UDP 9094, shipped as
NetworkPolicy `monitoring-alertmanager-cluster` in `manifests/netpol-allow.yaml` because
`monitoring-intra-metrics` does not list 9094.

### After merge, owner verifies

```sh
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n monitoring get pod \
  -l app.kubernetes.io/name=alertmanager -o wide
# expect two Ready pods on different nodes; -0 still on workernode1

# Alertmanager image has no shell. Query /api/v2/status from Grafana (or any
# monitoring pod with wget) against the Service; cluster.peers should be 2.
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n monitoring exec \
  deploy/prometheus-stack-grafana -c grafana -- \
  wget -qO- http://prometheus-stack-kube-prom-alertmanager:9093/api/v2/status

sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n monitoring get pvc \
  -l app.kubernetes.io/name=alertmanager
```

Send a test critical alert (Watchdog is severity none / `deadman` webhook — use a
throwaway `AlertmanagerConfig` or `amtool alert add` only if you accept a real
email). **Exactly one** email, not two. If two arrive, gossip is split (check
the 9094 NetworkPolicy and `--cluster.listen-address` on both pods).

### Prometheus and Grafana requests (same follow-up)

Both were BestEffort. Requests only, sized from live `kubectl top` plus 24 h
`container_memory_working_set_bytes` max (2026-11-05: Prometheus 639 Mi →
768 Mi request; Grafana 506 Mi → 576 Mi; sidecars 96 Mi each). **No memory
limit on Prometheus** — compaction / WAL replay can spike RSS; a limit OOM-kills
the detector. workernode2 was 1460 Mi / 38% requests and 2712 Mi / 71% usage;
adding ~1736 Mi of requests still fits under 3816 Mi allocatable (~84%).

### Dead-man's switch (Watchdog → healthchecks.io)

Watchdog fires continuously in Prometheus. Alertmanager routes it to receiver
`deadman`, which POSTs to the healthchecks.io ping URL stored as OpenBao
`secret/monitoring/alertmanager` property `watchdog_url` (never in git). Period
5 min + grace 5 min on the check; AM `repeat_interval: 1m` so pings land well
inside that window.

**Catches:** tuns power loss, WAN down, Prometheus down, both Alertmanager
replicas down, or AM egress blocked — the check stops receiving pings and pages
the owner.

**Does not catch:** Gmail-only failure (SMTP :465). Watchdog still pings :443, so
healthchecks stays up while email is silent. That is a different failure; prove
SMTP with a test critical alert.

Gossip notification-log dedup: two AM replicas send **~1 ping per interval**, not
two. One replica alone still pings (HA email is complementary, not a substitute).

**Proven 5 Nov 2026 (CST).** Owner silenced `alertname="Watchdog"` in the
Alertmanager UI (AM was not stopped). Check name: `homelab-watchdog`. Times
below are local CST (UTC-6) = UTC 6 Nov 2026.

| CST (5 Nov) | UTC (6 Nov) | Event | Source |
|---|---|---|---|
| 18:39 | 00:39 | Check `new -> up` (first ping after #81 rollout) | healthchecks event log |
| 19:55 | 01:55 | Ping #52, last ping before silence | healthchecks log |
| 19:55:41 | 01:55:41 | Silence starts (id 34d58af7, 15 m, comment "dead-man drill") | `amtool silence query --expired` |
| 20:05:46 | 02:05:46 | Check `up -> down`; DOWN email received ("success signal did not arrive on time, grace time passed") | email + event log |
| 20:10:41 | 02:10:41 | Silence ends by running out its 15 m (not expired manually) | amtool |
| 20:11 | 02:11 | Ping #53; check `down -> up`; UP email received ("downtime lasted 5 minutes, 35 seconds") | email + event log |

- Detection = **~10 min after last ping**, matching period 5 min + grace 5 min.
- Time to a human = ~10 min from lab going silent; recovery mail ~30 s after the
  silence ended.
- Ping cadence ~every 1.5 min (healthchecks log alternates 1 and 2 min), well
  inside the 5 min period. One ping per interval despite 2 AM replicas (dedup held).
- Letting the silence expire proved AM resumes Watchdog pings on its own
  (forgotten maintenance silence self-heals).
- Data note: each ping body is Alertmanager's webhook JSON (~1.9 KB): alert
  labels, annotations, `externalURL` (internal `*.apps.home.arpa` names). No
  secrets. healthchecks stores the last body. Accepted: internal non-routable
  names only. Option if ever unwanted: none in AM webhook (body is fixed);
  would need a relay.
- Does **not** prove the Gmail SMTP path (separate; one-email test on 5 Nov via
  #80).

**Rollout order (required).** ESO needs every listed property to render the
Secret. If `watchdog_url` is missing, the next sync is `SecretSyncedError` and
the **last-good Secret is kept** (email still works, Watchdog still on `null`
until a successful sync). Do not merge the ExternalSecret until the URL is
stored.

Owner steps:

(a) Store the ping URL (hidden prompt, prefix `https://hc-ping.com/` required):

```bash
scripts/openbao-breakglass.sh root-run watchdog-url
# prints only: stored (N chars)
```

(b) Merge this PR so Argo CD applies the ExternalSecret, NetworkPolicy :443, and
route tree.

(c) Force-sync ESO (hourly refresh otherwise):

```bash
ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n monitoring annotate externalsecret alertmanager-config-eso force-sync=$(date +%s) --overwrite'
```

Wait until `SecretSynced`. Confirm AM config has receiver `deadman` (do not
print the URL):

```bash
ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n monitoring exec alertmanager-prometheus-stack-kube-prom-alertmanager-0 -c alertmanager -- amtool config show --alertmanager.url=http://localhost:9093' | grep -E 'deadman|hc-ping' | sed 's|https://[^ ]*|https://<redacted>|'
```

(d) In the healthchecks.io UI, confirm check `homelab-watchdog` is receiving
pings (status up). Settings **must** be period **5 min**, grace **5 min**,
email integration on. Defaults are 1 day / 1 hour and would hide a 14 min gap.

(e) **Drill (silence, do not stop AM):** in the Alertmanager UI, silence
`alertname=Watchdog` **longer than 10 min** (use 15 m). DOWN email ~10 min
after the last ping (period 5 + grace 5). Then either expire the silence or
let it run out; UP email on the first ping back. Confirm the gap in the
healthchecks event log for `homelab-watchdog`. If the silence does not stop
pings, AM is still notifying — check the silence matchers.

Undo: PATCH the KV to drop `watchdog_url` only (never DELETE the whole secret —
that would drop SMTP). Then revert the ExternalSecret route to `null`.
