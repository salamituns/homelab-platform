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

**Public tenants** (proven with `personal-site`, live 2026-11-09; see
`k8s/tenants/personal-site/` for the real overlay): also set the Namespace label
`homelab.arpa/exposure: public` (the kit base defaults to `internal`) and include
`../../_kit/public-ingress`, which admits `public-gateway-nginx` on 8080. Do **not** set
`homelab.arpa/gateway-routes` — that label admits the namespace to `homelab-gateway`.

### 3. Deploy PR (`apps-deploy`)

Path the ApplicationSet watches: `apps/<app>/overlays/<env>`. Destination namespace is `<app>-<env>` (`CreateNamespace=false`). Put the HTTPRoute / Service / Deployment or Rollout here. Images must be `registry.home.arpa/<app>/*` (or `platform/*`), Cosign-signed, with SPDX SBOM, digest-pinned.

**Public app extra** ([edge-public.md](edge-public.md)): the HTTPRoute lives **here, in
`apps-deploy`**, and it is the only place that names public hostnames — `parentRefs` Gateway
`public-gateway` (namespace `nginx-gateway`), hostnames as configured in the Cloudflare
dashboard. This repo is public and stays hostname-free; `apps-deploy` is private.

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


## Phase 0 gate evidence (8 Nov 2026)

Tenant `demo-staging`, onboarded with the two golden-path PRs (homelab-platform #103 tenant kit, apps-deploy #1 app).

| # | Check | Evidence |
|---|---|---|
| 1 | Tenant pod lands on the apps pool | `demo-web` 1/1 Running on `workernode3`; Pod has `nodeSelector homelab.arpa/pool=apps` + the apps toleration (MutatingPolicy at CREATE); Deployment template has none (no Argo drift); Argo `demo-staging` Synced/Healthy |
| 2 | Untrusted images refused | server dry-run in `demo-staging`: unsigned `registry.home.arpa/platform/...` denied by `verify-tenant-images` (fails closed); `docker.io/library/nginx:1.27` denied by `require-digest` |
| 3 | Network isolation, against peers with no policies of their own | ingress: master host -> falcosidekick 200 (control), master host -> demo-web:3000 no connection; egress: demo DNS resolves (allowed), demo -> falcosidekick blocked |
| 4 | Secrets isolation, live | logged in to OpenBao as `demo-staging/eso` (role `tenant-demo-staging`, short-lived token in memory, revoked after): `apps/demo/staging/*` allowed (404, empty), `apps/govgraph/staging/*` **403**, `monitoring/alertmanager` **403**, `platform/nexus-pull` 200 by design |

Found on the way: the new worker could not resolve `registry.home.arpa` (ImagePullBackOff). `dns.yml` had been run
with `--limit gateway` (server only). Fixed live with `dns.yml --limit WorkerNode3`; `k8s-join.yml` now includes
`internal_dns` so a new node gets it at join time.

Lessons for test design: a "blocked" result proves nothing without a control that succeeds; test a namespace's
policy against peers that have no policies of their own (here: the master host and the exempt `falco` namespace),
or the other side's policy may be what blocked the traffic.
