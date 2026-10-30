# Runbook: upgrade Kubernetes by one minor version (kubeadm)

Use for: moving the cluster from 1.N to 1.N+1. kubeadm cannot skip a minor version, so 1.31 to 1.33 is two
runs of this runbook. Playbook: [`ansible/playbooks/k8s-upgrade.yml`](../../ansible/playbooks/k8s-upgrade.yml). ADR 0012.
Expected time: about 30 minutes per minor version.

## What happens, in order

| Step | Where | Effect |
|---|---|---|
| Preflight | Mac | Every node Ready, every pod Running/Completed, every node on the target minor or the one before |
| Backup | master | etcd snapshot + `/etc/kubernetes` to `/root/k8s-upgrade-backups/<time>-to-<version>/` (mode 0700: it holds the CA keys) |
| Repo + kubeadm | each node | apt repo switched to `pkgs.k8s.io/core:/stable:/v1.N+1`, kubeadm installed and held |
| `kubeadm upgrade apply` | master | New API server, controller manager, scheduler, kube-proxy, CoreDNS. `kubectl` drops for a few seconds |
| `kubeadm upgrade node` | each worker | Rewrites the kubelet config for the new version |
| Drain, kubelet, uncordon | each node, one at a time | Same flags and same impact as [drained-node-reboot.md](drained-node-reboot.md): MySQL and Alertmanager down while workernode1 is drained, Prometheus while workernode2 is |

Order is fixed: control plane before any kubelet. A kubelet may be older than the API server, never newer.

## 0. Before

- Check the add-ons for the target version: the Kyverno and ingress-nginx support tables, and
  `kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis` (empty = nothing calls a removed API).
- Find the newest patch release of the target minor:
  ```sh
  curl -qsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Packages | awk '/^Package: kubeadm$/{p=1} p&&/^Version:/{print $2; p=0}' | sort -V | tail -1
  ```
- The nightly PBS job backs up all three nodes. For extra safety, take a PBS backup of the master (108) first.

## 1. Dry run, then plan only

```sh
cd ansible
ansible-playbook playbooks/k8s-upgrade.yml -e k8s_version=1.32.13 --check --diff
ansible-playbook playbooks/k8s-upgrade.yml -e k8s_version=1.32.13      # backup, kubeadm on master, `kubeadm upgrade plan`, stop
```

Read the plan. Stop if any component config shows `MANUAL UPGRADE REQUIRED: yes`.

## 2. Apply

```sh
ansible-playbook playbooks/k8s-upgrade.yml -e k8s_version=1.32.13 -e k8s_upgrade_apply=true
```

The backup task is skipped when a backup for the same minute exists; a new run makes a new backup.

## 3. Verify

```sh
kubectl get nodes                                  # all Ready, all on the new version
kubectl get pods -A --no-headers | grep -v -E 'Running|Completed' || echo "all pods Running/Completed"
kubectl get applications -n argocd                 # all Synced/Healthy
kubectl get csr | grep Pending || echo "no pending CSRs"   # kubelet serving certs (ADR 0009)
kubectl top nodes
```

## Restore (if the control plane does not come back)

1. Restore VM 108 from the PBS backup taken before the run, or
2. on the master: stop the static pods (`mv /etc/kubernetes/manifests /root/manifests.off`), restore
   `/etc/kubernetes` from `etc-kubernetes.tgz`, then `etcdutl snapshot restore etcd.db --data-dir /var/lib/etcd-restored`
   and point the etcd manifest's data `hostPath` at it, and reinstall the previous kubeadm/kubelet/kubectl packages from the previous minor's repo.

## Log

| Date | From → to | Result |
|---|---|---|
| 2026-10-30 | 1.31.14 → 1.32.13 | All nodes Ready, 9/9 apps Healthy after ~60 s; ingress smoke test identical. Prometheus was still `Running 1/2` (WAL replay) when the playbook finished: the pod check now requires READY as well |
| 2026-10-30 | 1.32.13 → 1.33.13 | CoreDNS 1.11.3 → 1.12.0, Corefile (with the `home.arpa` forward) kept; pods resolve lab names; 9/9 Healthy after ~60 s |
