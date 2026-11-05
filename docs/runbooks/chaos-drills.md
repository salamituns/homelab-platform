# Runbook: Week 8 Chaos Drills (ADR 0018)

Owner-run procedures for the Week 8 drills. Drill 3 (expired cert) is below;
drill 4 (disk canary) follows it. Do not run these from an agent session.

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
