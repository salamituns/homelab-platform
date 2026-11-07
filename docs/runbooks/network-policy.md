# Runbook: NetworkPolicy enforcement (ADR 0015 section A)

Flannel enforces nothing on its own; `kube-network-policies` v1.1.2 (its own namespace, own
Argo CD app `kube-network-policies`) adds enforcement without touching the CNI. This round
covers the agent plus the `dev` allow set and default-deny. Every other namespace follows in
later rounds, ONE AT A TIME, in the ADR's order; do not batch them.

Design facts that decide everything below:

- **Fail-open (default `--fail-open=true`):** if an agent pod dies or the app is deleted,
  enforcement stops everywhere and traffic flows as if no policy existed. That makes rollback
  trivial and an agent outage silent, which is why the `KubeNetworkPoliciesAgentUnavailable`
  alert (monitoring) exists.
- **Selective capture:** only pods targeted by at least one policy are intercepted. With zero
  policies in the cluster the agent changes NO traffic at all (rollout step 1 proves this).
- **Same-node traffic is always accepted** (the agent's `meta skuid 0` rule): kubelet probes
  survive any deny. Cross-node node traffic is NOT exempt.
- **The agent evaluates post-DNAT/masquerade**, so policies must name pods and node
  masquerade addresses, never ClusterIPs.
- Known noise: upstream [#417](https://github.com/kubernetes-sigs/kube-network-policies/issues/417),
  fixed after v1.1.2 by [#420](https://github.com/kubernetes-sigs/kube-network-policies/pull/420) —
  tail packets of node-to-pod HTTPS probes can log DENY verdicts while the probes still pass.
  Expect a few such lines; they are noise, not outages, until the next release.
- **Image pin:** vendor file `kube-network-policies-install-v1.1.2.yaml` still references image
  `registry.k8s.io/networking/kube-network-policies:v1.1.1` (upstream install.yaml lag).
  Kustomize overlays `newTag: v1.1.2`. There is **no digest pin** (ROADMAP follow-up).

## Order of operations

Each step is separately reversible and must be checked before the next. All `kubectl` uses
the limited kubeconfig (`private/k8s-access/olatunde.kubeconfig`) unless it says admin path.

### Step 1: the agent, zero policies (NO traffic change)

1. Merge and sync the `kube-network-policies` app
   (`k8s/platform/apps/kube-network-policies.yaml`; the manifest is vendored and the app
   carries the namespace move and the v1.1.2 image pin, both explained in its kustomization).
2. Check the agents:

```sh
kubectl -n kube-network-policies get pods -o wide
```

   Expect one Running pod per node (master, workernode1, workernode2).
3. Prove nothing changed (no policies exist yet, so nothing is intercepted):

```sh
scripts/route-smoke.sh 192.168.1.240
scripts/netpol-proof-dev.sh
```

   The smoke must pass fully. The proof script's DENIED checks will report CONNECTED here —
   that is correct pre-deny behavior, the allowed checks must pass.
4. Watch one sync of any Argo CD app to confirm the apiserver<->admission path is unaffected
   (the iptables-mode kube-proxy coexistence check from the ADR; the agent adds nftables
   NFQUEUE rules alongside).

### Step 2: the dev allow policies (inert until a deny exists)

1. Merge and sync the belleshop-deploy PR with `base/netpol-dev-allow.yaml` (the appendix
   flows: intra-namespace, DNS to kube-dns, backend->mysql, gateway ingress to frontend 3000
   and backend 8000, Prometheus scrape of backend 8000, mysql ingress from backend and from
   the node masquerade addresses below).
2. Check they landed and are inert:

```sh
kubectl -n dev get networkpolicies
scripts/route-smoke.sh 192.168.1.240
```

### Step 3: the dev default-deny + proof

1. Merge and sync the belleshop-deploy PR with `base/netpol-dev-default-deny.yaml`
   (separate file and commit, reverting alone re-opens dev).
2. Run the proof:

```sh
scripts/netpol-proof-dev.sh
```

   Expect 6/6: allowed (gateway /api/healthz 200, backend->mysql connects, DNS resolves)
   and denied (backend->1.1.1.1:443 dropped, frontend->mysql:3306 times out — pre-deny it
   CONNECTS and dies on the MySQL banner, "bad header line"). If a DENIED check reports
   CONNECTED, the agent is not enforcing (fail-open: see the alert) — rollback below, then
   investigate the agent before retrying.
3. Read the agent's DENY verdicts for at least an hour (the appendix rule) and run one real
   BelleShop deploy or rollout promotion, because dev failures can hide until then:

```sh
kubectl -n dev get rollouts
kubectl -n kube-network-policies logs daemonset/kube-network-policies --tail=100
```

### Step 4+: later rounds (NOT this one)

Default-deny nginx-gateway, monitoring, argo-rollouts, argocd (one at a time, watch a sync),
then external-secrets and kyverno last (webhook lockout risk), then remove the dev NodePorts
30080/30081 (ADR 0015 A step 6). The allow sets per namespace are the ADR appendix; before
each deny, compare that namespace against its Services, ServiceMonitors, webhooks and
outbound config, as the review did for dev.

## The mysql-bao masquerade addresses (why mysql ingress allows six /32s)

`mysql-bao` (the .244 LoadBalancer, `externalTrafficPolicy: Cluster`) forwards OpenBao on
sectools to `mysql-0` through kube-proxy, which SNATs the source to the RECEIVING node's
address: its `cni0` bridge IP when mysql-0 sits on that node, its `flannel.1` IP when it
forwards cross-node. Verified live per node on 2026-11-02:

| Node | flannel.1 | cni0 |
|---|---|---|
| master | 10.244.0.0/32 | 10.244.0.1/32 |
| workernode1 | 10.244.3.0/32 | 10.244.3.1/32 (observed for the bao rotation, openbao.md) |
| workernode2 | 10.244.4.0/32 | 10.244.4.1/32 |

All six are allowed so the .244 announcement can move to any node without breaking
credential rotation. Never widen them to a /24: a pod subnet here admits every pod on that
node. To re-verify after a node change: `ssh <node> 'ip -4 addr show cni0 flannel.1'`, or
read the source address straight from the agent's verdict log during a rotation.

## Rollback, per step

| Step | Rollback |
|---|---|
| Agent | Delete the `kube-network-policies` app in Argo CD (or delete the DaemonSet). Fail-open: packets stop being intercepted, traffic behaves exactly as pre-install. The ClusterRole/Binding and namespace can stay or go with the app. |
| dev allows | Revert the belleshop-deploy PR; Argo prunes the policies. Inert anyway unless the deny exists. |
| dev default-deny | Revert exactly the `netpol-dev-default-deny.yaml` commit (its own file and commit); Argo prunes the single policy and dev re-opens while the allows and agent stay. |
| Agent down (unplanned) | Nothing to do for traffic (fail-open), but NO policy is enforced anywhere while it lasts: the `KubeNetworkPoliciesAgentUnavailable` alert fires; fix the agent, then rerun `scripts/netpol-proof-dev.sh`. |

## Reading the verdict logs

The agent logs one structured JSON line per verdict at the default verbosity. DENY lines are
the enforcement evidence:

```sh
kubectl -n kube-network-policies logs daemonset/kube-network-policies --tail=100 | grep -i deny
```

Each line carries the verdict, the policy that decided it, and both endpoints (src/dst with
pod or node context), so a denied flow names the exact rule to fix. ALLOW lines exist too but
are far noisier; grep them only when hunting a specific expected flow. When reading:

- A DENY from a node address to a pod's HTTPS port right after a probe connection closed is
  the #417 tail-packet noise — check whether the probe actually failed before touching policy.
- A DENY naming a ClusterIP as destination means the policy was written pre-DNAT: policies
  must select pods (or the masquerade /32s), never ClusterIPs.
- Nothing at all from a pod means no policy targets it (selective capture) — not that traffic
  is allowed.

## What was verified live before this rollout (2026-11-02)

Pod labels in dev (`app=backend/frontend/mysql`, stable and canary share `app=backend`);
Service ports (frontend 3000, backend 8000, mysql 3306, mysql-bao .244); kube-dns pods
(`k8s-app=kube-dns`, kube-system); gateway Service `externalTrafficPolicy: Local` (resolves
an ADR unverified item — with Local the source at the gateway pod is the LAN client, but the
gateway's own connections to dev pods still come from the gateway pods, which is what the
dev ingress rules select); the per-node flannel.1/cni0 addresses in the table above; busybox
wget present in the frontend image; the limited kubeconfig can exec in dev and read agent
logs. Not verifiable with the limited cert and left to the owner at apply time: the
server-side dry-run of NetworkPolicies (the Role is read-only for them) and the actual
post-sync behavior, which the proof script covers.

## Round 2: nginx-gateway (first of the four; the others follow one at a time)

Allow set + default-deny in the SAME PR (`k8s/platform/nginx-gateway/netpol-allow.yaml` and
`netpol-default-deny.yaml`): with the agent live an allow is never inert, so shipping allows
first "to be safe" would already isolate the namespace.

Flows (all verified live 2026-11-02, details in the file header): data-plane ingress 80/443
from the LAN (ETP Local, real client IP) and from the pod CIDR; data-plane egress to the four
route backends (dev 3000/8000, grafana 3000, argocd-server 8080, rollouts dashboard 3100)
plus agent-grpc 8443 to the control plane; control-plane ingress 8443 from the data plane and
from the master pod subnet (apiserver webhook); DNS and API (.90:6443, endpoints verified)
for every pod.
## Round 2: monitoring (second of the four)

Allow set + default-deny in one PR, in `k8s/platform/monitoring/manifests/` (the monitoring
app's plain-manifest source; no kustomization to register - every YAML file in that path
syncs with the app).

Flows (live evidence in the file header): DNS + API for every pod; prometheus scrapes to
10.244.0.0/16 (pod targets) and to the node IPs on the exact ports read from the live
Endpoints (kubelet 10250/10255/4194, kube-proxy 10249, node-exporter 9100 on all three;
etcd 2381, controller-manager 10257, scheduler 10259, apiserver 6443 on the master);
port-limited intra-namespace metrics; alertmanager to smtp.gmail.com:465 (public internet
minus the private ranges); grafana 3000 from nginx-gateway; prometheus 9090 from
argo-rollouts (the canary analysis). falcosidekick is not deployed - not allowed yet.
## Round 2: argo-rollouts (third of the four)

Allow set + default-deny in one PR, registered in the argo-rollouts kustomization (the
lesson from the brief: a file that exists but is not listed never deploys).

Flows (live evidence in the file header): DNS + API for the controller and dashboard;
dashboard 3100 from the Gateway; controller -> Prometheus 9090 for canary analysis. The
controller's 8090 metrics port has no ServiceMonitor, so nothing scrapes it and no ingress
rule exists for it. The GitHub plugin download egress (`:443` to `0.0.0.0/0`) is gone: the
binary is copied from an in-lab image ([argo-rollouts-plugin.md](argo-rollouts-plugin.md)).

Watch after sync:

```sh
scripts/netpol-proof.sh nginx-gateway   # 4 routes + control plane + a denied check + verdicts
scripts/route-smoke.sh 192.168.1.240    # the full 20-check sweep, unchanged behavior expected
```

Then read the agent DENY verdicts for an hour (the #417 probe-tail noise is expected: tail
packets of node-to-pod HTTPS probes denied while the probes pass) and watch one Argo CD sync
- the webhook path (apiserver -> 8443) only proves itself on a real sync.

Rollback: revert the PR. Argo CD prunes both files and the namespace returns to no policies
at all (the pre-agent state; the data-plane 80/443 listener never depended on policy).
scripts/netpol-proof.sh monitoring    # grafana route, app health, a denied check, verdicts
```

Then watch **TargetDown** and the kube-* target dashboards in Grafana for an hour: a missing
scrape flow fails QUIETLY (the scrape just stops), which is exactly what the alert covers.
The apiserver/etcd/scheduler/controller-manager scrapes are cross-node node traffic from
the prometheus pod - never exempt.

Rollback: revert the PR; the monitoring app has prune enabled, so both files disappear with
it and the namespace returns to no policies.
scripts/netpol-proof.sh argo-rollouts   # dashboard route, app health, a denied check, verdicts
```

Then run a REAL canary (promote or a BelleShop image bump): the analysis query to
Prometheus only proves itself under a rollout. If the analysis fails, read the DENY
verdicts for the controller pod.

Rollback: revert the PR; the argo-rollouts app prunes both files.
## Round 2: argocd (LAST of the four; the risky one - apply while watching a sync)

Allow set + default-deny in one PR, in `k8s/platform/cluster-config/` (the cluster-config
app's plain-manifest path; no kustomization to register). Designed ADDITIVE with the seven
NetworkPolicies Argo CD's install already ships in the namespace (listed from live in the
allow file header): those restrict ingress only, this PR adds the egress sides of the same
pairs (redis/repo-server clients, dex, gitea, the public Helm repos) plus the deny
backstop, and belt-and-braces ingress for the UI and the ApplicationSet webhook.

The one trap the live read found: upstream's applicationset webhook rule uses a
namespaceSelector, which matches pods, not the apiserver's cross-node masquerade address -
the ipBlock 10.244.0.0/24 rule in the allow file is the reliable form for node traffic
(the same appendix pattern as the gateway webhook).

Watch after sync (while it happens):

```sh
scripts/netpol-proof.sh argocd   # UI route, every app Synced/Healthy, two denied checks, verdicts
```

Then force a REAL sync cycle: refresh + sync any app (the repo-server gitea fetch, redis
and the webhook path all prove themselves only under a sync), and read the DENY verdicts
for an hour. If apps go Unknown/OutOfSync, the fetch path is broken: read the verdicts,
fix the flow, resync.

Rollback: NOT just revert - cluster-config syncs with prune disabled, so deleting the
files does not delete the live policies. Revert the PR, then delete the nine policies by
hand (the exact kubectl command is in netpol-argocd-default-deny.yaml).
