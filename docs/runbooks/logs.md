# Runbook: Loki logs and Grafana Alloy (ADR 0017 PR 1)

Owner-only apply (Argo CD after merge). This runbook is the **post-merge proof** for
[ADR 0017](../adr/0017-logs-dashboards-belleshop-slos.md) decision 1: Loki SingleBinary
on a worker `local-path` PVC, Alloy DaemonSet collecting every namespace except
`kube-system`, Grafana Loki datasource via the existing sidecar.

Nothing here is agent-applied to the cluster.

## What git deploys

- Argo Application `loki` (`k8s/platform/apps/loki.yaml`), destination `monitoring`.
- Charts: grafana-community/loki `21.0.0` (OSS Loki 3.7.9; official `grafana/loki` 7.x is
  Grafana Enterprise Logs only) and grafana/alloy `1.15.0` (Alloy v1.21.3), both by digest.
- Extra manifests: `k8s/platform/loki/manifests/` (datasource ConfigMap + named netpols).
- `monitoring-intra-metrics` also allows 3100 / 12345 / 7946 (same PR).
- AppProject `platform` sourceRepos includes both Helm repos.

Alloy -> API `:6443` is already `monitoring-api-egress` (`podSelector: {}`). DNS is
already `monitoring-dns-egress`.

## Rollback

1. Revert the merge commit (or delete `k8s/platform/apps/loki.yaml` and the Loki/Alloy
   values+manifests, and revert the `monitoring-intra-metrics` port adds).
2. Argo CD prunes the Application's objects (`prune: true`).
3. **PVC:** the Loki StatefulSet uses `enableStatefulSetAutoDeletePVC: false`. After prune
   you can be left with `monitoring/storage-loki-0` (name from the chart's
   `volumeClaimTemplates`). Delete it only when you intend to drop the 7d of logs:

   ```bash
   ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n monitoring get pvc'
   # then, if retiring Loki: delete the PVC named storage-loki-0
   ```

## Post-merge checks (read-only: admin SSH `get|describe|logs` / Grafana Explore)

Use `ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf …'` unless noted.

### 1. Pods Ready, PVC Bound on a worker

```bash
kubectl -n monitoring get sts,ds,pod,svc -l 'app.kubernetes.io/name in (loki,alloy)'
kubectl -n monitoring get pvc,pv
kubectl -n monitoring describe pvc storage-loki-0
# VOLUMEBINDINGMODE is WaitForFirstConsumer: the PV nodeAffinity must be a worker
# (workernode1 / workernode2), never master.
```

Expect: Loki StatefulSet 1/1, Alloy DaemonSet 3/3 (master + two workers), PVC Bound.

### 2. Host `df` on the PVC node (owner decision 3)

SSH to the worker that holds the PV (not the Mac, not `kubectl exec`):

```bash
df -hT /
# record: filesystem, size, used, avail, use%. 10Gi Loki plus the node's other PVCs
# (Prometheus 5Gi or MySQL 5Gi) must leave headroom.
```

Write the numbers back into this runbook under "Recorded" below.

### 3. Logs from BelleShop, not kube-system

From the Grafana pod (it has `wget`) or Grafana Explore as a Viewer:

```bash
# Loki query API through the Grafana pod (in-cluster, no Mac Docker)
kubectl -n monitoring exec deploy/prometheus-stack-grafana -c grafana -- \
  wget -qO- --post-data='query={namespace="dev"}' \
  'http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/query'
```

Expect streams with `namespace=dev` and pods from **both workers** (backend replicas)
and, after a non-kube-system pod exists on master, master as well. `{namespace="kube-system"}`
must be empty (owner decision 2).

Grafana Explore: datasource **Loki** (`uid: loki`), same LogQL. The sidecar only watches
`monitoring` for datasources (`LABEL=grafana_datasource`, not `NAMESPACE=ALL`).

### 4. Node memory requests stay under 75%

```bash
kubectl describe nodes | awk '/^Name:|^  cpu |^  memory |^Allocated resources:|^  Resource /{print}'
```

Expect workernode requests **< 75%** memory after Loki 256Mi + Alloy 64Mi (+ reloader 16Mi).
If a worker crosses 75%, move Loki (delete pod so `WaitForFirstConsumer` can rebind — that
**does** lose the filesystem volume) or drop Loki limits before Prometheus retention.

## Recorded (fill after merge)

| Check | Result | When |
|---|---|---|
| Loki node | `loki-0` on workernode1, PVC `storage-loki-0` 10Gi `local-path` Bound | 2026-11-04 |
| `df -h /` on that node | `/dev/sda2` 79G, 28G used, **48G free (37%)**. local-path does not enforce the 10Gi; the 7d retention is what bounds it | 2026-11-04 |
| `{namespace="dev"}` streams | 4 pods (2 backend, 2 frontend) from workernode1 + workernode2, after the label fix in #60 | 2026-11-04 |
| `{namespace="kube-system"}` empty | yes (13 namespaces ingested, none kube-system) | 2026-11-04 |
| Duplicates | 0 pods seen from more than one `node` label (per-node discovery, #60) | 2026-11-04 |
| Node memory requests | master 15%, workernode1 53%, workernode2 38% (limits 22% / 95% / 93%: watch worker limits) | 2026-11-04 |

After #60 Alloy logged `entry too far behind` / `dropping data` for a while: the relabel created new streams and
Alloy re-sent each pod's old history, which Loki rejects. Harmless and one-off; only old history is lost.
