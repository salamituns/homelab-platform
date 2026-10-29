# Runbook: drained reboot of the k8s nodes

Use for: applying Proxmox changes that wait for a VM restart (`qm pending`), kernel updates, or a
node-loss drill. One node at a time. Expected time: about 10 minutes per node.

## What breaks while a node is down

| Node (VMID) | Impact |
|---|---|
| master (108) | `kubectl` and Argo CD syncs stop for 1-2 minutes; running apps keep serving |
| workernode2 (102) | Prometheus is down: its local-path PV lives on this node |
| workernode1 (107) | BelleShop MySQL and Alertmanager are down: their local-path PVs live on this node |

local-path volumes are a folder on one node's disk, so those pods cannot move; they wait as Pending until
the node is back. No PodDisruptionBudgets exist, so the drain never waits for anything.

## 0. Check the cluster is healthy first

```sh
kubectl get nodes
kubectl get pods -A --no-headers | grep -v -E 'Running|Completed' || echo "all pods Running/Completed"
kubectl get applications -n argocd
```

## 1. Per node: drain, reboot from Proxmox, wait, uncordon

Order: master, workernode2, workernode1. Example for master:

```sh
kubectl drain master --ignore-daemonsets --delete-emptydir-data --timeout=180s
ssh root@tuns 'qm reboot 108 && (qm pending 108 | grep "^new" || echo "no pending changes left")'
kubectl wait --for=condition=Ready node/master --timeout=300s && kubectl uncordon master
```

- Reboot with `qm reboot`, not `sudo reboot` in the guest: pending Proxmox changes (boot order, disk
  options) only apply when the QEMU process restarts. A guest reboot keeps the same process.
- After the master reboot, `kubectl wait` fails with `connection refused` while the API server starts.
  Run it again.
- `kubectl wait` can return `condition met` before the node has even gone NotReady (the API server
  marks it NotReady only after ~40 s). Before draining the next node, check that all pods are back:
  ```sh
  kubectl get pods -A --no-headers | grep -v -E 'Running|Completed' || echo "all pods Running/Completed"
  ```

## 2. Verify

```sh
ssh root@tuns 'for id in 108 102 107; do qm pending $id | grep "^new" || echo "$id: none pending"; done'
terraform -chdir=terraform/proxmox plan          # No changes
kubectl get applications -n argocd               # all Synced/Healthy
kubectl get csr | grep Pending || echo "no pending CSRs"
kubectl top nodes                                # metrics-server answers, kubelet TLS still valid
```

## 3. Rebalance (optional)

The scheduler never moves running pods. The last node drained comes back nearly empty while the
other worker carries everything. Restart the stateless Deployments so the scheduler places them again
(it prefers the less-used node):

```sh
kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c
kubectl -n argocd rollout restart deploy
kubectl -n monitoring rollout restart deploy
kubectl -n dev rollout restart deploy
```

## Log

| Date | Why | Result |
|---|---|---|
| 2026-10-29 | Apply pending boot order and scsi0 options (ADR 0010) | All 3 nodes rebooted, `qm pending` empty, plan: No changes, 9/9 Argo apps healthy, kubelet certs valid to 2027-10-27. Afterwards 26 of 41 pods on workernode2 (73% memory), 6 on workernode1 |
