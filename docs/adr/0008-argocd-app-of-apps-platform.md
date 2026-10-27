# ADR 0008: Cluster add-ons declared in git, managed by Argo CD (app of apps)

- Status: Accepted
- Date: 2026-10-27

## Context

The cluster add-ons were installed by hand in August: MetalLB, ingress-nginx, Argo Rollouts and
local-path from upstream manifests, kube-prometheus-stack with `helm install`. Nothing in git said
which version ran, and a deleted namespace could only come back by someone remembering the commands.
A survey on 2026-10-27 found more:

- The **BelleShop app** (prune: true) owned platform objects: the MetalLB address pool and L2 config,
  the Argo CD ingress and the Rollouts dashboard ingress. A commit to the shop could delete the
  cluster's load-balancer addresses.
- Three objects in `monitoring` were applied by hand and tracked by nothing: the Grafana ingress, the
  BelleShop ServiceMonitor and its dashboard.
- `monitoring/grafana-admin` (Grafana's admin login) exists only in the cluster.

## Decision

| Question | Choice | Why |
|---|---|---|
| Pattern | One hand-applied root Application (`k8s/platform/bootstrap/root.yaml`) that syncs `k8s/platform/apps/`: one Application per add-on, plus the AppProject | Everything after the first `kubectl apply` is a git commit |
| Versions | Same versions as live (adopt, do not upgrade). Upgrades are separate, reviewable commits | Adoption changes ownership, nothing else |
| Raw-manifest add-ons | Upstream files vendored byte-for-byte, SHA-256 in `k8s/platform/VENDOR.md`, wrapped by kustomize | No sync depends on GitHub; an upgrade is a visible diff |
| kube-prometheus-stack | Helm chart 88.3.0 from its repo, values from git (multi-source), `releaseName: prometheus-stack` | Same object names as the old Helm release, so Argo CD adopts instead of duplicating |
| Project | AppProject `platform`: this repo + the prometheus chart repo, 7 namespaces, 8 cluster-scoped kinds | A bad commit in one add-on cannot create arbitrary cluster objects |
| Ownership | Platform objects leave BelleShop; app-specific monitoring (ServiceMonitor, dashboard) joins BelleShop | Each object has exactly one owner, and it is the right one |
| Root app sync | Automated, selfHeal, **prune off** | Removing an add-on must be deliberate |
| Child sync | Manual for the first adoption sync, then automated with selfHeal + prune | Look at the first diff before trusting automation |
| Not managed (yet) | Argo CD itself; flannel; kube-proxy | Argo CD self-management needs a bootstrap story; the CNI is kubeadm's |

Verified before writing: `kubectl diff` of every vendored manifest and the rendered chart against the
live cluster showed no change, except MetalLB's runtime `caBundle` (ignored) and Helm hook objects (run as Argo hooks).

## Consequences

- `helm list` still shows `prometheus-stack`; never run `helm upgrade` on it again (Argo CD would fight it).
  Its release Secrets are deleted after adoption.
- Secrets and data are not in git: deleting `monitoring` brings back every object, but not
  `grafana-admin` (Week 5: External Secrets) and not the Prometheus/Alertmanager PVC data.
- Week 4 (Kyverno) should stop any Application outside `k8s/platform/apps` from using project `platform`.
