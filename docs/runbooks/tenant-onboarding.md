# Runbook: onboard a tenant app (ADR 0019 D1, D5)

Golden path: **two PRs**, no `kubectl` by hand. Under an hour for a fourth app.

| PR | Repo | What |
|---|---|---|
| 1 (platform) | `homelab-platform` | Copy `k8s/tenants/_template/<env>/` to `k8s/tenants/<app>/<env>/`, replace `APP`, add `eso` to `k8s/platform/tenants/eso-tokenreview-tenants.yaml`, include the overlay from `k8s/platform/tenants/kustomization.yaml` |
| 2 (deploy) | `apps-deploy` | `apps/<app>/base` + `apps/<app>/overlays/<env>` (digest-pinned workload). The ApplicationSet creates Application `<app>-<env>` into namespace `<app>-<env>` |

Namespaces, quotas, NetworkPolicies, developer RBAC, `nexus-pull`, and the apps-pool mutate are **platform-owned**. App YAML cannot create ResourceQuota, LimitRange, NetworkPolicy, Role, or RoleBinding (`AppProject/apps` blacklist) and cannot create cluster-scoped objects (empty clusterResourceWhitelist).

## Owner steps (in order)

### 0. Once per lab (Phase 0)

1. Merge this kit so Argo CD syncs `AppProject/apps`, ApplicationSet `apps`, Application `tenants`, and `ImageValidatingPolicy/verify-tenant-images`.
2. Create Gitea repo `tunsgit/apps-deploy` (empty `main` is fine). Register it in Argo CD the same way as `belleshop-deploy` (repo secret in `argocd`, TLS CA already in `argocd-tls-certs-cm`). Until the repo exists the ApplicationSet shows a generator error; that is expected.
3. Confirm `workernode3` is Ready with `homelab.arpa/pool=apps:NoSchedule`.

### 1. OpenBao (before the namespace exists is OK; ESO retries)

```sh
scripts/openbao-breakglass.sh root-run tenant demo staging --dry-run   # plan only
scripts/openbao-breakglass.sh root-run tenant demo staging             # 2 hidden unseal-share prompts
```

No token on the Mac: the root token is minted, used and revoked on sectools (root revoked 2026-11-02).

Details: [`tenant-secrets.md`](tenant-secrets.md). Role name must be `tenant-<app>-<env>` (the SecretStore patch).

### 2. Platform PR (`homelab-platform`)

```sh
cp -R k8s/tenants/_template/staging k8s/tenants/<app>/staging
# Replace APP in that kustomization.yaml with <app>.
# Add subject eso in namespace <app>-staging to
#   k8s/platform/tenants/eso-tokenreview-tenants.yaml
# Add the overlay to k8s/platform/tenants/kustomization.yaml resources.
```

Phase 0 dummy `demo/staging` is already wired. Render before merge:

```sh
kubectl kustomize k8s/tenants/demo/staging
kubectl kustomize k8s/platform/tenants
```

### 3. Deploy PR (`apps-deploy`)

Path the ApplicationSet watches: `apps/<app>/overlays/<env>`. Destination namespace is `<app>-<env>` (`CreateNamespace=false`). Put the HTTPRoute / Service / Deployment or Rollout here. Images must be `registry.home.arpa/<app>/*` (or `platform/*`), Cosign-signed, with SPDX SBOM, digest-pinned.

### 4. Prove (Phase 0 gate)

Run as the limited cert unless noted. Dummy namespace is `demo-staging`.

**Unsigned image denied** (Kyverno `verify-tenant-images` / `restrict-registries`):

```sh
# A pod whose image is registry.home.arpa/personal-site/foo:unsigned (no signature)
# must be rejected. Same for docker.io/*.
```

**Tenant pod lands on workernode3** (MutatingPolicy `tenant-apps-pool`):

```sh
ssh Master 'sudo -n kubectl -n demo-staging get pods -o wide'
# NODE must be workernode3; pod spec.nodeSelector["homelab.arpa/pool"]=apps
# and a NoSchedule toleration for that key.
```

**Cross-namespace traffic denied** (default-deny + gateway-only ingress):

```sh
# From a pod in another tenant (or from a platform ns that is not
# homelab-gateway-nginx): connect to the demo Service ClusterIP — must fail.
# From the gateway data-plane pods to the app port: must succeed once a
# workload listens. Do not write ClusterIPs into NetworkPolicies.
```

**Cross-tenant secret read denied**:

```sh
# OpenBao role tenant-demo-staging can read secret/data/apps/demo/staging/*
# and secret/data/platform/nexus-pull only. A read of
# secret/data/apps/govgraph/staging/* with that role must be 403.
# Proven by scripts/openbao-breakglass-test.sh (section 12) against a throwaway OpenBao.
```

## Rollback

- Remove the overlay from `k8s/platform/tenants/kustomization.yaml` and the TokenReview subject; Argo prune deletes the namespace objects (`tenants` has `prune: true`).
- Delete the `apps-deploy` overlay; ApplicationSet prune deletes the Application.
- `bao delete auth/kubernetes/role/tenant-<app>-<env>` and `bao policy delete tenant-<app>-<env>`.

Do not `kubectl delete namespace` as the first step: let Argo prune so the kit stays the source of truth.
