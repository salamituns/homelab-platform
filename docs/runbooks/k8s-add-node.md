# Runbook: add a Kubernetes worker (apps pool)

Use for: cloning `workernode3` (ADR 0019 D2) and joining it with
`homelab.arpa/pool=apps:NoSchedule`. Playbook:
[`ansible/playbooks/k8s-join.yml`](../../ansible/playbooks/k8s-join.yml).
Expected time: about 20 minutes after the VM answers SSH.

The same playbook is the template for a later apps worker: add a `module.vm`
map entry, inventory host in `k8s_workers` **and** `k8s_apps_workers`, DNS
name, then `--limit` that host.

## What happens, in order

| Step | Where | Effect |
|---|---|---|
| Falco + Alloy values | git / Argo CD | DaemonSets tolerate `homelab.arpa/pool=apps:NoSchedule` so they land on the node. **MetalLB speaker does not** — the admin VIP (`.240`–`.244`) must stay announced only from the platform workers |
| Terraform | `terraform/proxmox` | Clone template 109 as VMID 128, 4 vCPU / 8 GB / 80 GB, `192.168.1.91` |
| DNS | gateway | `workernode3.home.arpa` |
| Join playbook | WorkerNode3 | `baseline`, `lab_ca_trust`, `static_ip`, `k8s_node` (containerd.io **2.2.1** held, kube **1.33.13** held), `containerd_registry`, `kubeadm join` with JoinConfiguration taint+label, kubelet-serving CSR, `lynis` |
| Prove | Mac | Node Ready, taint+label, Falco/Alloy/Flannel/kube-proxy pods, **no** speaker pod |

`k8s-join.yml` hosts `k8s_apps_workers` (`serial: 1`). Always pass
`--limit WorkerNode3` so a future extra apps node is not joined by accident.

## MetalLB speaker stays off the apps node

Speaker is an L2 announcer. If it ran on `workernode3`, a noisy or compromised
app workload would share the host that answers ARP for Grafana, Argo CD, and
the shop VIP. kube-proxy, Flannel, kube-network-policies, and node-exporter
already `toleration.operator: Exists` for `NoSchedule`, so CNI and metrics
still run. Falco and Alloy needed an explicit apps-pool toleration.

## 0. Before

- Git with this change is merged (or Argo is pointed at the branch) so Falco
  and Alloy roll **before** the node joins. Otherwise those DaemonSets stay
  off the new node until the next sync.
- Confirm `.91` is still free (`ping`, `ip neigh`, DNS).
- Do **not** reuse VMID 104–106 (PBS backup groups still exist). This VM is 128.

## 1. Plan / check (no host change)

```sh
cd terraform/proxmox
terraform plan -out=workernode3.tfplan
# Expect: Plan: 1 to add, 0 to change, 0 to destroy. Only module.vm["workernode3"].

cd ../../ansible
ansible-playbook playbooks/k8s-join.yml --syntax-check
ansible-playbook playbooks/dns.yml --check --diff   # existing gateway; adds the new A record
```

`--check` of `k8s-join.yml --limit WorkerNode3` is only useful after the VM
exists and SSH works. Until then, syntax-check and ansible-lint are the gate.

## 2. Apply

```sh
cd terraform/proxmox
terraform apply workernode3.tfplan

# Wait until SSH answers (cloud-init + qemu-guest-agent).
ssh -o StrictHostKeyChecking=accept-new tunsadmin@192.168.1.91 true

cd ../../ansible
ansible-playbook playbooks/dns.yml --check --diff
ansible-playbook playbooks/dns.yml

ansible-playbook playbooks/k8s-join.yml --limit WorkerNode3 --check --diff
ansible-playbook playbooks/k8s-join.yml --limit WorkerNode3
```

The join token is 15 minutes, `no_log: true`, written only to
`/root/kubeadm-join.yaml` mode 0600 and deleted in `always`. Do not print it.
If `kubectl logs` to the new node fails with `tls: internal error`, re-run:

```sh
scripts/approve-kubelet-serving-csrs.py --dry-run
scripts/approve-kubelet-serving-csrs.py
```

## 3. Prove

```sh
ssh Master 'sudo -n kubectl get node workernode3 -o wide'
ssh Master 'sudo -n kubectl get node workernode3 --show-labels'
ssh Master 'sudo -n kubectl describe node workernode3 | sed -n "/Taints/,/Unschedulable/p"'
ssh Master 'sudo -n kubectl get pods -A -o wide --field-selector spec.nodeName=workernode3'
```

Expect: Ready; label `homelab.arpa/pool=apps`; taint
`homelab.arpa/pool=apps:NoSchedule`; pods for falco, alloy, kube-proxy,
kube-flannel, kube-network-policies, node-exporter; **no**
`speaker-` pod on that node.

## Rollback

```sh
ssh Master 'sudo -n kubectl drain workernode3 --ignore-daemonsets --delete-emptydir-data --timeout=180s'
ssh Master 'sudo -n kubectl delete node workernode3'
ssh tunsadmin@192.168.1.91 'sudo kubeadm reset --force'
# Then from terraform/proxmox:
terraform destroy -target='module.vm["workernode3"]'
```

Remove the DNS record by reverting `ansible/inventory/group_vars/all/dns.yml`
and re-running `playbooks/dns.yml`. Falco/Alloy tolerations can stay: they are
harmless without a node that carries the taint.

## Pins (must not drift)

| Package | Version | Why |
|---|---|---|
| containerd.io | `2.2.1-1~ubuntu.24.04~noble` (held) | Live workers; 2.4.x is what ci-agent runs |
| runc | 1.3.4 (ships inside containerd.io) | Not a separate apt package on the workers |
| kubelet, kubeadm, kubectl | `1.33.13-1.1` (held) | Cluster version |
| kubernetes-cni | `1.2.0-2.1` (held) | Live workers; hold so it cannot float |

Do not change `lynis.service` `ExecStart`. The `lynis` role already keeps it.

## First real run (WorkerNode3, 7 Nov 2026): five bugs no dry-run caught

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | (caught in review) | `containerd.io` package ships `disabled_plugins = ["cri"]` | role owns `/etc/containerd/config.toml` |
| 2 | `No package matching 'containerd.io'` | repo added, but `cache_valid_time: 3600` skipped the refresh (cloud-init had just updated apt) | refresh apt whenever a repo task changes |
| 3 | `no available installation candidate for kubernetes-cni=1.2.0-2.1` | pin copied from WorkerNode2, which got it from an older minor's repo; v1.33 repo has only 1.6.0 | pin `1.6.0-1.1`. Fleet drift (1.5.1 / 1.2.0) goes to the patch cycle |
| 4 | join failed, output hidden | `regex_search(..., '\1')` returns a **list**: config had `token: "['…']"` | `\| first`; on failure the play now prints kubeadm's output with the token redacted |
| 5 | CSR approval failed on the Mac | approving CSRs needs cluster-admin; the Mac's kubectl is least-privilege | script runs on Master with `admin.conf` (`ansible.builtin.script`) |
| 6 | Falco CrashLoopBackOff on the new node | cloud image kernel 6.8.0-88 refuses `perf_event_open` to least-privileged eBPF (CAP_PERFMON) | install the current kernel and reboot before joining |

Proven: stale-cache case reproduced on purpose (repos removed, cache refreshed) and the fixed role passed; full play `failed=0`; node Ready with taint/label, serving CSR issued, Falco/Alloy/node-exporter/kube-network-policies running, no MetalLB speaker; re-run idempotent.
