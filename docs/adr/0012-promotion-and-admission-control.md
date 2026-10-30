# ADR 0012: Promotion by config-repo PR, Kyverno admission, and the upgrade it needs first

- Status: Accepted
- Date: 2026-10-30

## Context

Week 3 builds, scans and signs BelleShop images in Nexus. None of that reaches the cluster yet:

- `dev` runs `belleshop-backend:latest` and `belleshop-frontend:latest` from the nodes' local image cache
  (`imagePullPolicy: IfNotPresent`), loaded by the old pipeline. The `nexus-pull` Secret exists but nothing uses it.
- `mysql:8.0` comes from Docker Hub, by tag.
- Nothing checks an image at admission. Any pod with any image can run in any namespace.

Week 4 has to close two gaps: get the signed digest into what Argo CD deploys, and refuse anything else.

Survey of the cluster on 2026-10-30, before choosing tools:

| Item | Found | Upstream support |
|---|---|---|
| Kubernetes | 1.31.14, kubeadm, packages held | 1.31 out of support since 2025-10-28 |
| Kyverno that is tested on 1.31 | 1.16 only | 1.16 out of support since 2026-08-20; 1.19 (current) is tested on 1.33-1.35 |
| ingress-nginx | controller v1.11.3 | tested to 1.30 only; the project was retired in March 2026, last release v1.15.1 (1.31-1.35) |
| Deprecated API calls | none (`apiserver_requested_deprecated_apis` empty) | |

## Decision

| Question | Choice | Why |
|---|---|---|
| Where the digest is written | New config repo `belleshop-deploy` (Gitea). The `k8s/` manifests move there; Argo CD watches it instead of BelleShop | App repo says *what the code is*, config repo says *what runs*. A commit to the config repo never triggers a build, so promotion cannot loop |
| Who writes it | Jenkins, on `main` builds only, opens a PR with the new digests. Bot account `ci-promote` can open PRs on `belleshop-deploy` and nothing else | CI never pushes to a branch Argo CD deploys. The owner's merge is the promotion approval; a revert is the rollback |
| Not chosen | Commit to BelleShop `main` (CI writes production, loops); PR in BelleShop with a path filter (loop held off by a rule); Argo CD Image Updater (another controller with git write, and it does not check Cosign signatures) | |
| Admission | Kyverno, policies in `homelab-platform` synced by Argo CD | Policy as code, reviewed like everything else |
| Our images | `registry.home.arpa/belleshop/*` must carry a Cosign signature from `cosign.pub` (no tlog, as signed) and are rewritten to their digest at admission | A tag can move between the check and the pull; a digest cannot |
| Third-party images | In app namespaces, any other image must come through a Nexus Docker Hub proxy and be pinned by digest. Not re-signed by us | One registry to watch and scan; no pull-rate limits. Scanning and signing third-party images is a pipeline we do not need yet |
| Other rules | No `:latest`, no tag-only references, CPU/memory requests and limits on every container | |
| Scope | App namespaces only (`dev`, later `prod`), by namespace label. Platform namespaces are not checked | Upstream images there are not ours to sign |
| Kyverno down | Fail **closed** for the app namespaces | An outage blocks new BelleShop pods; it cannot disable the control silently, and it cannot stop kube-system or Argo CD |
| Kyverno size | One admission controller replica | Nodes are at 50-57% memory. Costs availability, not safety |
| Pod Security | `restricted` enforced on app namespaces, after a `warn` pass | PR-1 already made BelleShop's pods non-root, read-only, no privilege escalation |
| Rollout of each policy | `Audit` first, read the reports, then `Enforce` | Know what a policy would block before it blocks it |
| Kubernetes first | Upgrade 1.31 -> 1.32 -> 1.33 (kubeadm, one minor at a time) **before** Kyverno; then Kyverno 1.19 | Admission control on top of two unsupported components is the wrong base |
| ingress-nginx first | v1.11.3 -> v1.15.1 before the cluster upgrade | v1.15.1 is tested on both 1.31 and 1.33, so it carries across both steps |
| Upgrade method | Ansible playbook, `serial: 1`, control plane then workers, drain before kubelet; etcd snapshot and kubeadm config copied off the master first | Repeatable for 1.34 and later; the same drain rules as the reboot runbook |

## Not now

- Replacing ingress-nginx (retired, no more security fixes) with a Gateway API implementation: own ADR, after Week 4.
- A `prod` namespace and auto-merge for `dev` promotions.
- Re-signing third-party images after our own scan.
- Bumping MetalLB, flannel, Argo CD, Rollouts, local-path and metrics-server: patch versions, stable APIs, not needed for 1.33.
- A highly available control plane or Kyverno.

## Consequences

- Two node-by-node maintenance passes; BelleShop MySQL and Prometheus are down while their node is drained
  (local-path PVs).
- Argo CD's `belleshop` Application changes repo. BelleShop keeps `k8s/` until the switch is verified, then removes it.
- `dev` starts pulling from Nexus: Nexus becomes a runtime dependency of the app namespace, not only of CI.
- A Kyverno outage stops BelleShop deploys and pod restarts in `dev` until it is back.
