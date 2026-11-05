# Runbook: Week 8 Chaos Drills (ADR 0018)

Owner-run procedures for the Week 8 drills. Drill 3 (expired cert), drill 4
(disk canary), and drill 5 (node loss, plan only) are below. Do not run these
from an agent session.

---

## Drill 3: Expired TLS Certificate (`chaos-drill3`)

### Blast-Radius Guardrails (Owner Override of ADR 0018)

Per the owner's architectural override of ADR 0018's Gateway SNI option:

1. **Never touch `homelab-gateway` (`192.168.1.240`), `Certificate/apps-home-arpa` (`*.apps.home.arpa`), `ClusterIssuer/lab-ca`, or any `HTTPRoute`.**
2. The drill runs entirely inside a dedicated namespace, `chaos-drill3`, using an isolated `nginx-unprivileged` TLS server (`Service/chaos-expiry:8443`) probed in-cluster by `blackbox_exporter`.
3. `Probe/chaos-expiry` carries `slo: chaos-drill` (not `slo: belleshop-availability`), so BelleShop availability recording rules and multi-window burn-rate alerts (`BelleShopSLOFastBurn` / `BelleShopSLOSlowBurn`) are never affected.

### Design Notes & Live Cluster Constraints

- **`cert-manager` minimum duration (`1h`):** `webhook.cert-manager.io` rejects `spec.duration < 1h` (`certificate duration must be greater than 1h0m0s`). `Certificate/chaos-expiry` uses `duration: 1h`, `renewBefore: 20m`, and `ECDSA P-256`.
- **`lab-root.crt` X.509 Name Constraints (`Permitted: DNS:home.arpa`):** Both `lab-root.crt` and `cert-manager/lab-ca-intermediate` enforce `X509v3 Name Constraints: critical, Permitted: DNS:home.arpa`. Both Go `crypto/x509` (`blackbox_exporter`) and OpenSSL check **every** DNS SAN on a leaf certificate against `PermittedDNSDomains`; adding `chaos-expiry.chaos-drill3.svc` to `dnsNames` causes TLS verification to fail immediately at `t = 0` (`DNS name "chaos-expiry.chaos-drill3.svc" is not permitted by any constraint`), which suppresses `probe_ssl_earliest_cert_expiry`. Instead:
  - `Certificate/chaos-expiry` sets `dnsNames: [chaos-expiry.chaos-drill3.home.arpa]`.
  - `blackbox_exporter` defines module `http_2xx_chaos` with `tls_config.server_name: chaos-expiry.chaos-drill3.home.arpa` and probes `https://chaos-expiry.chaos-drill3.svc:8443/` over cluster DNS.
- **Directory mount + periodic reload (no `subPath`):** `Secret/chaos-expiry-tls` is mounted at `/etc/nginx/tls` without `subPath` so kubelet atomic symlink updates propagate when `cert-manager` renews the Secret at `t + 40m`. A background loop reloads `nginx` every 300 seconds (`tty: false`, so Falco's `Terminal shell in container` rule — which requires `proc.tty != 0` — stays silent).

---

### Phase 1 — PR A (`week8-drill3`): Set-up & Pre-Expiry Page (`< 7d`)

#### 1. Merge PR A (`week8-drill3`)

PR A adds:
- `k8s/platform/apps/project.yaml`: allows destination namespace `chaos-drill3`.
- `k8s/platform/apps/chaos-drill3.yaml`: Argo CD `Application` (`CreateNamespace=true`, `prune: true`, `selfHeal: true`).
- `k8s/platform/chaos-drill3/certificate.yaml`: `Certificate/chaos-expiry` (`duration: 1h`, `renewBefore: 20m`, `issuerRef.name: lab-ca`).
- `k8s/platform/chaos-drill3/deployment.yaml`: `ConfigMap/chaos-expiry-nginx`, `Deployment/chaos-expiry` (pinned to `workernode2`, `restricted` pod security), and `Service/chaos-expiry` (`:8443`).
- `k8s/platform/chaos-drill3/netpol.yaml`: `chaos-drill3-default-deny` (Ingress + Egress) and `chaos-drill3-allow-blackbox-ingress` (TCP `8443` from `monitoring` `prometheus-blackbox-exporter`).
- `k8s/platform/blackbox/values.yaml`, `manifests/probes.yaml`, `manifests/netpol.yaml`: `http_2xx_chaos` module, `Probe/chaos-expiry` (`interval: 30s`, `slo: chaos-drill`), and egress allow to `chaos-drill3` `app: chaos-expiry` on TCP `8443`.

#### 2. Verify Sync & Initial Telemetry (`t = 0..5m`)

Run from `Master` (`192.168.1.90`):

```sh
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n chaos-drill3 get certificate,secret,deploy,pod,svc,netpol
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n monitoring get probe chaos-expiry
```

Expected state within 2 minutes of sync:
- `Certificate/chaos-expiry` is `Ready=True`.
- `Pod/chaos-expiry-*` is `1/1 Running` on `workernode2`.
- In Prometheus (`https://prometheus.apps.home.arpa`):
  - `probe_success{probe="chaos-expiry"} == 1`
  - `(probe_ssl_earliest_cert_expiry{probe="chaos-expiry"} - time())` is `~3600` seconds (`~0.041` days).
  - `(certmanager_certificate_expiration_timestamp_seconds{namespace="chaos-drill3",name="chaos-expiry"} - time())` is `~3600` seconds.
  - BelleShop probes (`probe=~"shop-home|shop-api|shop-api-debug"`) remain at `probe_success == 1` and `~87` days to expiry.

#### 3. Verify `for: 1h` Alert Firing (`t = 60m`)

- At `t + 40m` (`renewBefore: 20m`), `cert-manager` renews `Secret/chaos-expiry-tls` (`notAfter` moves to `t + 100m`), and `nginx` reloads the new certificate within 5 minutes so `probe_success{probe="chaos-expiry"}` stays `1` across `t = 60m`.
- At `t + 60m`, the 1-hour `for:` window completes on both rules in `k8s/platform/monitoring/manifests/homelab-tls-expiry-prometheusrule.yaml`:
  - `HomelabTlsCertExpiringSoon{probe="chaos-expiry",severity="warning"}` (`< 21d`) -> **Firing**
  - `HomelabTlsCertExpiringSoon{probe="chaos-expiry",severity="critical"}` (`< 7d`) -> **Firing** (delivered via Alertmanager `severity=critical` email route)
  - `HomelabCertManagerCertExpiringSoon{namespace="chaos-drill3",name="chaos-expiry",severity="warning"}` -> **Firing**
  - `HomelabCertManagerCertExpiringSoon{namespace="chaos-drill3",name="chaos-expiry",severity="critical"}` -> **Firing** (delivered via Alertmanager `severity=critical` email route)

---

### Phase 2 — PR B (`week8-drill3-inject`): Inject Renewal Failure & Actual Expiry

#### 1. Merge PR B (`week8-drill3-inject`)

PR B changes a single line in `k8s/platform/chaos-drill3/certificate.yaml`:

```yaml
  issuerRef:
    name: chaos-drill3-no-such-issuer
    kind: ClusterIssuer
```

#### 2. Expected Detection After `notAfter` Passes (`<= 60m` after last renewal)

1. **Renewal failure (`renewBefore: 20m` before `notAfter`):**
   - `cert-manager` creates a `CertificateRequest` referencing `ClusterIssuer/chaos-drill3-no-such-issuer`, which stays `Ready=False` (`IssuerNotFound`).
   - `Secret/chaos-expiry-tls` is not updated; `nginx` continues serving the existing leaf until its `notAfter` timestamp passes.
2. **Certificate expiration (`time() > notAfter`):**
   - `blackbox_exporter` fails the TLS handshake against `https://chaos-expiry.chaos-drill3.svc:8443/` (`x509: certificate has expired or is not yet valid`):
     ```promql
     probe_success{probe="chaos-expiry"} == 0
     ```
   - `cert-manager` reports negative remaining lifetime:
     ```promql
     certmanager_certificate_expiration_timestamp_seconds{namespace="chaos-drill3",name="chaos-expiry"} - time() < 0
     ```
   - `HomelabCertManagerCertExpiringSoon{namespace="chaos-drill3",name="chaos-expiry",severity="critical"}` remains **Firing**.
   - BelleShop probes (`probe=~"shop-home|shop-api|shop-api-debug"`) remain `probe_success == 1` with `~87` days remaining, and `BelleShopSLOFastBurn` / `BelleShopSLOSlowBurn` remain **Inactive**.

---

### Phase 3 — Clean-up (Teardown PR)

Once detection evidence (`probe_success{probe="chaos-expiry"} == 0`, negative `certmanager_certificate_expiration_timestamp_seconds - time()`, and Alertmanager email/UI screenshots) is captured:

1. Open and merge a revert/clean-up PR that:
   - Deletes `k8s/platform/apps/chaos-drill3.yaml` and `k8s/platform/chaos-drill3/`.
   - Removes `{ server: https://kubernetes.default.svc, namespace: chaos-drill3 }` from `k8s/platform/apps/project.yaml`.
   - Removes `http_2xx_chaos` from `k8s/platform/blackbox/values.yaml`, `Probe/chaos-expiry` from `k8s/platform/blackbox/manifests/probes.yaml`, and the `chaos-drill3` egress entry from `k8s/platform/blackbox/manifests/netpol.yaml`.
2. After Argo CD prunes `Application/chaos-drill3` and all resources inside `chaos-drill3`, delete the empty namespace on `Master`:
   ```sh
   sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf delete namespace chaos-drill3
   ```
3. Confirm in Prometheus/Alertmanager that `Probe/chaos-expiry` is gone and `HomelabTlsCertExpiringSoon` / `HomelabCertManagerCertExpiringSoon` resolve within 5 minutes.

---

## Drill 4: Disk-full canary (`chaos-drill4`)

Isolated emptyDir fill on **master** only. Does not trip `NodeFilesystemAlmostOutOfSpace`.
The detector is `HomelabDiskCanaryEvicted` (**warning → UI only**, not email).

### Must not

- `dd`/`fallocate` on worker or master **root**. Fill MySQL / Prometheus / Loki PVCs.
- Let the pod schedule on `workernode1` or `workernode2` (abort if it does).
- `kubectl delete pod homelab-disk-canary` while the Application still exists:
  `selfHeal: true` will recreate a **new** fill.

### Expected timings

| T | What |
|---|---|
| merge + ~1–2 min | Application Synced; pod Running on `master` |
| seconds after Running | `dd` hits `emptyDir.sizeLimit: 256Mi` (command asks for 300Mi) |
| kubelet eviction | Pod `Failed` / `Reason=Evicted`; Argo health **Degraded**, sync still **Synced** (spec unchanged) |
| +1 min | `HomelabDiskCanaryEvicted` pending then firing (rule `for: 1m`) in Prometheus/AM UI |
| revert + owner delete | objects gone; alert resolves |

### Owner steps (PR A, branch `week8-drill4`)

1. Baseline (Grafana pod wget or the Prometheus UI):

   ```
   node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} * 100
   HomelabDiskCanaryEvicted
   ```

   Record free-% on master `.90`, wn1 `.89`, wn2 `.84`.
2. Merge PR A. Wait for `argocd app chaos-drill4` Synced.
3. `kubectl -n chaos-drill4 get pod homelab-disk-canary -o wide` — NODE must be `master`. If not, abort (revert, do not wait).
4. Watch `kubectl -n chaos-drill4 describe pod homelab-disk-canary` for Evicted.
5. Confirm `kube_pod_status_reason{reason="Evicted",pod="homelab-disk-canary"} == 1` (or `last_terminated_reason`). Alert warning in the UI, no email.
6. Re-check nodefs % — must not drop more than ~2 points. If master free falls toward 15%, merge revert immediately.

### Abort

- Pod not on master.
- Nodefs on any node moves more than ~2 percentage points.
- `sizeLimit` ignored and `dd` finishes (pod stays Running with a 300Mi file): merge revert; do not `qm` anything.

### Clean-up (PR B, branch `week8-drill4-revert`)

`platform-root` has **`prune: false`**. A resources finalizer on the child does **not** delete the Application when git drops it. After PR B merges:

```sh
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n argocd delete application chaos-drill4
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf delete namespace chaos-drill4
```

The first command is the one the finalizer needs: Argo then prunes the Failed pod and NetworkPolicy. The namespace from `CreateNamespace` is **not** removed by that prune. Do not skip the namespace delete (drill 3 left a running app for the same reason).

---

## Drill 5: Node Loss (workernode1 / VM 107) — plan only

**This section is a design/runbook.** Do not `qm shutdown` from an agent session.
The owner injects and recovers on the Proxmox host. Live facts below were
checked on the cluster the morning of **2026-11-05 CST** (HEAD `3c21079`).
Re-run the pre-checks immediately before injection; numbers drift.

Hypothesis: graceful ACPI shutdown of **workernode1** (VM **107**) is detected
inside two minutes by `HomelabKubeNodeNotReadyFast`, the shop stays reachable
on HTTPS via Gateway on workernode2, and MySQL (PVC-pinned) comes back after
`qm start 107` without restore. The interesting finding is **not** “the node
goes NotReady”; it is what goes **blind**, what **cannot move**, and whether
waiting past the default 300 s unreachable window **stampedes** workernode2.

### Why 107, never 102 or 108

| VM | Role | Why not |
|---|---|---|
| 102 workernode2 | Prometheus STS PVC, Grafana, Gateway data-plane (`homelab-gateway-nginx` + VIP `.240`), Argo CD server, Rollouts controller, cert-manager, ESO, Kyverno | Killing it blinds the detector and takes down `*.apps.home.arpa`. ADR 0018 forbids this. |
| 108 master | etcd / API | Out of scope. |
| 107 workernode1 | MySQL, Loki, Alertmanager, half the shop, Argo controllers, blackbox, kube-state-metrics | Prometheus and Gateway stay up. Detector still evaluates. |

No `kubectl drain`. Drain would evict immediately and skip the unreachable
clock. `qm shutdown` is the failure mode.

Never `qm stop 107` (hard power-off). Use ACPI `qm shutdown 107 --timeout 180`.

### Live capacity (2026-11-05, `kubectl describe node`)

Two workers, each **2 CPU / ~3816 Mi** allocatable, **no PodDisruptionBudgets**.

| Node | CPU req (lim) | Mem req (lim) | Notes |
|---|---|---|---|
| master | 1110 m / 55% (lim 22%) | 606 Mi / 15% | Control plane + CoreDNS replica. Do not schedule the stampede here (`NoSchedule`). |
| workernode1 | 1200 m / 60% (lim **97%**) | 2090 Mi / 54% (lim **195%**) | Already limit-overcommitted on CPU. |
| workernode2 | 935 m / 46% (lim **93%**) | 1460 Mi / 38% (lim **93%**) | Headroom on **requests**; almost no headroom on **limits**. |

### Inventory: every pod on workernode1

**PVC-pinned (Stay Pending until 107 is Ready again; local-path WaitForFirstConsumer, no expansion):**

| Namespace/pod | Owner | Requests / limits | PVC |
|---|---|---|---|
| `dev/mysql-0` | STS `mysql` | 250 m / 512 Mi ; 1 CPU / 1 Gi | `mysql-data-mysql-0` (bound on 107) |
| `monitoring/alertmanager-prometheus-stack-kube-prom-alertmanager-0` | STS | 100 m / 200 Mi | Alertmanager PVC |
| `monitoring/loki-0` | STS | 256 m / 512 Mi | `storage-loki-0` 10 Gi |

**DaemonSets (die with the node; never reschedule to 102):** falco, flannel,
kube-network-policies, kube-proxy, MetalLB speaker, Alloy, node-exporter.

**Movable after default `unreachable` `tolerationSeconds: 300` (Deployments / STS without PVC):**

| Namespace/pod | Owner | Requests / limits |
|---|---|---|
| `argo-rollouts/argo-rollouts-dashboard-*` | Deploy | none declared |
| `argocd/argocd-application-controller-0` | STS (no PVC) | none |
| `argocd/argocd-applicationset-controller-*` | Deploy | none |
| `argocd/argocd-dex-server-*` | Deploy | none |
| `argocd/argocd-notifications-controller-*` | Deploy | none |
| `argocd/argocd-redis-*` | Deploy | none |
| `argocd/argocd-repo-server-*` | Deploy | none |
| `dev/backend-*` (1 of 2) | Rollout `backend` | 128 m / 128 Mi ; 250 m / 512 Mi |
| `dev/frontend-*` (1 of 2) | Deploy | 128 m / 128 Mi ; 250 m / 512 Mi |
| `falco/falcosidekick-*` | Deploy | 64 Mi |
| `kube-system/coredns-*` (1 of 2; other on master) | Deploy | 70 Mi |
| `kube-system/metrics-server-*` | Deploy | 200 Mi |
| `local-path-storage/local-path-provisioner-*` | Deploy | none |
| `metallb-system/controller-*` | Deploy | none |
| `monitoring/prometheus-blackbox-exporter-*` | Deploy | 32 Mi |
| `monitoring/oauth2-proxy-alertmanager-*` | Deploy | 32 Mi |
| `monitoring/oauth2-proxy-prometheus-*` | Deploy | 32 Mi |
| `monitoring/prometheus-stack-kube-prom-operator-*` | Deploy | none |
| `monitoring/prometheus-stack-kube-state-metrics-*` | Deploy | none |

Movable **requests** sum ≈ **686 Mi**. workernode2 + that ≈ **2146 Mi** vs
**3816 Mi** allocatable (~56%). **The scheduler will admit them on requests.**

Movable **limits** sum ≈ **1514 Mi** plus several Argo / operator pods with
**no memory limit**. workernode2 is already **3552 Mi limits / 3816 Mi
allocatable (93%)**. After the stampede, limits sit well above 100%. If those
pods actually use their limits (or unbounded Argo RSS), **kubelet eviction /
OOM-kill on workernode2** is the real risk.

**Stay on workernode2 (survive the whole drill):** `argocd-server`; Rollouts
controller; cert-manager ×3; ESO ×3; Kyverno ×4; remaining backend + frontend
replicas; Gateway `homelab-gateway-nginx` + `nginx-gateway`; Grafana;
Prometheus STS; DS falco/flannel/netpol/alloy/node-exporter.

**Stay on master:** API, etcd, scheduler, kube-proxy/flannel/falco DS, one
CoreDNS.

No PDBs. Adding a PDB would **not** keep MySQL or Alertmanager up (involuntary
disruption). Do **not** add PDBs as a pre-drill “fix”; that would hide the
finding.

### What goes down, and for how long

Two clocks:

1. **Node NotReady** ≈ tens of seconds after ACPI (kubelet heartbeat).
2. **Default unreachable taint 300 s** on Deployments/STS. Until then the
   pods stay Assigned to 107 (Unknown). After 300 s the scheduler places
   movable pods on workernode2.

| Workload | First ~40 s | Until 300 s | After 300 s if 107 still down | After `qm start 107` |
|---|---|---|---|---|
| Gateway VIP `.240` / `*.apps.home.arpa` TLS | Up (wn2) | Up | Up | Up |
| Shop **frontend** (replica on wn2) | HTML up | HTML up | HTML up | Both replicas |
| Shop **API** / login | Fail (MySQL on 107) | Fail | Fail (MySQL still Pending) | Recovers when `mysql-0` Running |
| MySQL | Down | Down, Pending | **Pending forever** (PVC) | Running on 107 |
| Loki | Down | Down, Pending | **Pending** | Running on 107 |
| Alertmanager | Down | Down, Pending | **Pending — no email the entire drill** | Running on 107 |
| Prometheus | Up (wn2) | Up | Up | Up |
| Grafana UI | Up (wn2, Gitea OIDC, in-cluster Prometheus DS) | Up | Up | Up |
| Browser Prometheus UI | **Down** (`oauth2-proxy-prometheus` on 107) | Down | Recovers when proxy reschedules | Recovers |
| Browser Alertmanager UI | Down | Down | Still down (STS+PVC) | Recovers |
| Argo CD UI (`argocd-server` wn2) | Page may load | Syncs freeze (controller/redis/dex/repo on 107) | Controllers on wn2; UI works under load | Controllers prefer 107 again when Ready |
| Rollouts controller | Up (wn2) | Up | Up | Up |
| Rollouts dashboard | Down | Down | Reschedules | Recovers |
| ESO / cert-manager / Kyverno | Up (wn2) | Up | Up | Up |
| blackbox | Down | Down | Reschedules; probes resume while MySQL still down | Normal |
| kube-state-metrics | Down | Down | Reschedules | Recovers |
| node-exporter / Alloy / Falco on 107 | Dead | Dead | Dead | New DS pods on 107 |

**Default recommended duration:** keep 107 down **~3–4 minutes** after
shutdown (long enough for `HomelabKubeNodeNotReadyFast` at 2 m, **short of
300 s**). Stateless pods then come back on 107. No stampede.

**Optional extended duration (~12 min):** wait through TargetDown (`for: 10 m`).
That **does** stampede workernode2. Only do this if you are watching Grafana
memory and are ready to `qm start 107` the moment wn2 approaches eviction.

### Will they fit on workernode2?

- **Requests: yes.** 1460 Mi + ~686 Mi ≈ 2146 Mi < 3816 Mi.
- **Limits / unbounded: no safety margin.** 93% limits already; Argo CD pods
  have **zero** memory limits. OOM/eviction on wn2 is an **abort**.
- **Never fit while 107 is down:** `mysql-0`, Alertmanager, Loki (PVC pin).
  Those stay **Pending**. That is expected, not a scheduler bug.
- Master is not a landing zone (`NoSchedule`).

### Visibility matrix (what the owner can still see)

| Surface | Path | During 107 down |
|---|---|---|
| Grafana | `https://grafana.apps.home.arpa` → Service `prometheus-stack-grafana:80` (no oauth2-proxy; Grafana Gitea OIDC) on wn2 | **Primary observation path.** Prometheus datasource is in-cluster, not the browser UI. |
| Prometheus browser | `https://prometheus.apps.home.arpa` → `oauth2-proxy-prometheus:80` on **wn1** | **Blind until the proxy reschedules** (~300 s) or 107 is back. |
| Alertmanager browser + email | STS+PVC on **wn1** | **Blind the entire drill.** Watchdog cannot page. |
| Argo CD UI | `https://argocd.apps.home.arpa` server on wn2 | UI shell may load; **reconcile is frozen** until controllers move or 107 returns. |
| kubectl | `ssh Master` / limited kubeconfig against `.90` | **Works.** Use this for Pending/Unknown and `describe node`. |
| Shop | `https://belleshop.apps.home.arpa` | Frontend 200; `/healthz` and `/api/token` fail without MySQL. |
| Gitea / OpenBao / PBS | VMs **122 / 120 / 123**, not on 107 | Must stay up. Abort if they flap. |

Do **not** move Alertmanager off 107 as a pre-drill PR. That is an owner
decision after the drill (email silence is itself a finding). Recorded here:
**leave AM on workernode1.**

### Alerts: will / will not fire

Live `GET /api/v1/rules` from Grafana (37 groups, 2026-11-05):

| Alert | Live `for` / severity | Evaluated where | Email? | Expected this drill |
|---|---|---|---|---|
| `HomelabKubeNodeNotReadyFast` | **2 m / critical** (`up{job="node-exporter"} == 0`) | Prometheus on wn2 | **No** (AM down) | **Fires in Prometheus/Grafana UI.** This is the detector. |
| `TargetDown` | 10 m / warning | Prometheus on wn2 | No | Fires only if 107 stays down ≥10 m (extended mode). |
| `KubeNodeNotReady` / `KubeNodeUnreachable` | 15 m / warning | Needs kube-state-metrics | No | **Likely dead** while ksm is on 107; even if ksm moves, 15 m is past the default window. |
| `Watchdog` | firing / none | Prometheus | No path to email | Stays firing in Prometheus; **nobody is mailed**. |
| `BelleShopAvailabilityBurnFast` | SLO 14.4× / 30 m window | Needs blackbox | No | Inactive until blackbox is down long enough **and** still scraping. In the **short** window blackbox is also on 107, so SLO may **not** compute. In **extended** mode blackbox reschedules, probes fail on MySQL/API, Fast-burn **can show in Grafana** still with **no email**. |
| Falco / cert-manager / disk canary | n/a | mixed | No | Not the signal for this drill. |

**Detect = Grafana alert list + `kubectl get nodes`, not the inbox.**

### Pre-drill PR?

**No placement PR. No PDB PR. Do not move Alertmanager.**

`HomelabKubeNodeNotReadyFast` is already on `main` (`k8s/platform/monitoring/manifests/homelab-node-notready-prometheusrule.yaml`)
and **loaded live** (`homelab.node-notready`, inactive, `for: 120`, severity
critical).

Owner hygiene before injection (not a git PR):

- Drill-4 leftover: Application `argocd/chaos-drill4` was still present
  after PR #73 (`prune: false` + `resources-finalizer`). Delete the
  Application **and** namespace `chaos-drill4` so Argo health is honest.
- Confirm PBS snapshot of 107 is from this morning (see below).
- Confirm Gitea (**122**), sectools/OpenBao (**120**), and PBS (**123**) are running.

### PBS backup of VM 107 (live 2026-11-05)

Job `daily-all`: snapshot at **01:30** to `pbs-store1`, **excludes 101 and 123**,
includes 107.

Last 107 backup: **`pbs-store1:backup/vm/107/2026-11-05T07:33:19Z`** (UTC) =
**01:33 CST** the same morning. Next run **2026-11-06 01:30 CST**.

QEMU guest agent is on (`agent=1`). Disk 80 G, 2 vCPU, 4 G RAM. Snapshot parent
`before-ansible-hardening` (2026-01-24) is **not** the restore point; PBS is.

Restore is **not** the happy path. Happy path is `qm start 107` and MySQL
resumes on the existing PVC. Restore only if 107 will not boot.

### Owner commands

**Pre-checks (from Master / a kubeconfig that can get/describe):**

```sh
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf get pdb -A
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n argocd get applications
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A --field-selector spec.nodeName=workernode1
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n dev get pod mysql-0 -o wide
```

**Shop + Grafana (from the Mac, `curl -q`):**

```sh
curl -qsS -o /dev/null -w 'shop:%{http_code}\n' https://belleshop.apps.home.arpa/
curl -qsS -o /dev/null -w 'healthz:%{http_code}\n' https://belleshop.apps.home.arpa/healthz
curl -qsS -o /dev/null -w 'grafana:%{http_code}\n' https://grafana.apps.home.arpa/login
```

**PBS age (Proxmox host):**

```sh
pvesh get /cluster/backup --output-format json
pvesh get /nodes/pve/qemu/107/status/current --output-format json
```

**Injection (Proxmox host only):**

```sh
qm shutdown 107 --timeout 180
# wait; do not qm stop
qm status 107
```

**Watch (Master + Grafana):**

```sh
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -w
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A --field-selector spec.nodeName=workernode1
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n monitoring get pod -l app.kubernetes.io/name=alertmanager -o wide
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n dev get pod mysql-0
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf describe node workernode2 | sed -n '/Allocated resources/,+12p'
```

In Grafana: `HomelabKubeNodeNotReadyFast`, node-exporter `up` for 107,
`BelleShopAvailabilityBurnFast`, workernode2 memory. Inbox will be silent.

**Recovery:**

```sh
qm start 107
qm status 107
# wait Ready
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n dev get pod mysql-0 -o wide
sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n dev exec mysql-0 -- mysql -N -e 'SELECT 1'
curl -qsS -o /dev/null -w 'healthz:%{http_code}\n' https://belleshop.apps.home.arpa/healthz
```

MySQL data plane: `SELECT 1` plus the shop `healthz`/login path. Do not restore
from PBS unless `mysql-0` cannot start.

If a movable pod is already Running on workernode2 when 107 returns, leave it.
Do not drain wn2 to “put things back.”

### Abort criteria (start 107 immediately; never `qm stop`)

- workernode2 memory.available collapsing or kubelet eviction / OOM.
- VMs **102 / 108 / 120 / 122 / 123** change state (workernode2, master,
  sectools/OpenBao, Gitea, PBS). Do not touch them.
- Cluster API on `.90` unreachable.
- Shutdown hangs past `--timeout 180` **and** the guest is still running:
  start it again if unsure; do **not** `qm stop`.
- You are past ~4 minutes and did **not** choose extended mode: **start 107**
  before the 300 s reschedule.

### Expected outcome (short window)

- `workernode1` NotReady; Fast-burn node-exporter alert **visible in Grafana**
  at ~2 m; **no email**.
- Shop HTML up; API/login down; MySQL/Loki/AM Pending.
- Gateway, Grafana, Prometheus, ESO, cert-manager, Kyverno, Rollouts
  controller stay up on wn2.
- After `qm start 107`: node Ready, `mysql-0` Running on 107, `SELECT 1` ok,
  shop `healthz` 200. No PBS restore.

### Postmortem

After the live run, write `docs/postmortems/YYYY-MM-DD-drill5-node-loss.md`
(same shape as drill 1/2: timeline CST, detect vs mitigate, what was blind,
whether the 300 s stampede happened, PBS unused). Link it from ADR 0018 when
that file is touched next. This plan commit does **not** invent that
postmortem.

### Drill 5 safety-check corrections (independent read-only check, 2026-11-05 09:46-09:54 CST)

- `argocd-application-controller-0` is a **StatefulSet** pod: it does NOT move at 300 s; it stays Terminating on
  workernode1 until the node returns (never force-delete it). Only the 18 ReplicaSet pods (~686 Mi requests,
  ~688 Mi working set) would move, so the requests fit on workernode2 (~56%).
- If the outage ran past ~5 m 40 s and workernode2 hit `memory.available < 100Mi`, the **BestEffort**
  `prometheus-0` (~555 Mi) and `grafana` (~349 Mi) would be evicted first. Hence the short window: start VM 107
  again **before 5 minutes**.
- No `failurePolicy: Fail` webhook that intercepts pods runs on workernode1 (Kyverno, cert-manager and ESO are all
  on workernode2). The MetalLB webhook on workernode1 only guards `metallb.io` CRDs.
- kubelet `shutdownGracePeriod: 0s` on workernode1: an ACPI shutdown stops containers via systemd, not the kubelet's
  graceful pod sequence. InnoDB recovered cleanly after the last such shutdown (2026-10-29/31). Restore point:
  PBS `vm/107/2026-11-05T07:33:19Z`.
