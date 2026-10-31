# ADR 0013: Replace `ingress-nginx` with a Kubernetes Gateway API controller

- Status: Accepted (owner, 2026-10-31)
- Date: 2026-10-31

## Context

`ingress-nginx` was retired by Kubernetes SIG Network and the Security Response Committee in March 2026
([upstream retirement announcement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)). Release `v1.15.1`
is the end of the line: it receives no further bugfixes or CVE patches. In Week 4 ([ADR 0012](0012-promotion-and-admission-control.md))
we upgraded `ingress-nginx` from `v1.11.3` to `v1.15.1` only so the controller remained on a tested support matrix while
stepping Kubernetes through `1.31 -> 1.32 -> 1.33`.

Before selecting a replacement, we surveyed the cluster and everything that depends on `ingress-nginx` today:

### Lab constraints

| Constraint | Current state | Impact on Gateway choice |
|---|---|---|
| Kubernetes | `v1.33.x` on kubeadm (1 control plane, 2 workers) | Must support Kubernetes 1.33 and Gateway API `v1` (`gateway.networking.k8s.io/v1`) |
| Node memory | 2 workers × 4 GB RAM, currently at 50–57% used | Heavy service-mesh control planes or high-memory proxies risk pushing workers over 75% during rollouts |
| CNI | Flannel (`kube-flannel-ds`, VXLAN) | Rules out CNI-integrated gateways unless we also replace the CNI |
| LoadBalancer | MetalLB L2 (`192.168.1.240–192.168.1.243`); `.240` is bound to `ingress-nginx-controller` | A spare VIP (`.244`) is available for parallel bring-up before moving `.240` |
| GitOps | Argo CD app-of-apps (`homelab-platform` and `belleshop-deploy`), `ServerSideApply=true`, `ServerSideDiff=true` | CRDs and controller manifests must vendor cleanly from a pinned Helm chart or release manifest without OutOfSync drift |
| Progressive delivery | Argo Rollouts `belleshop-backend` uses `trafficRouting.nginx` (`stableIngress: belleshop-api-ingress`) | Must migrate to `HTTPRoute` weight splitting via [`argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi`](https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi) | Kyverno admission | Enforces `restricted` PSA and signed/digest-pinned images in `dev` (`homelab-platform` namespaces are excluded) | Gateway control/data-plane pods live in their own platform namespace |

### Existing `Ingress` inventory (5 total)

All five `Ingress` objects use `ingressClassName: nginx` on HTTP port 80 (no TLS secrets on the cluster Ingresses;
`ssl-redirect: "false"` everywhere):

| # | Namespace / Name | Host(s) | Path (`pathType`) | Annotations beyond `ssl-redirect: "false"` | Target Service | `HTTPRoute` mapping |
|---|---|---|---|---|---|---|
| 1 | `argocd/argocd-server-ingress` | `argocd.local` | `/` (`Prefix`) | `backend-protocol: "HTTP"` (default in `HTTPRoute`) | `argocd-server:80` | `PathPrefix: /` -> `argocd-server:80` |
| 2 | `monitoring/grafana-ingress` | `grafana.local` | `/` (`Prefix`) | none | `kube-prometheus-stack-grafana:80` | `PathPrefix: /` -> `kube-prometheus-stack-grafana:80` |
| 3 | `argo-rollouts/argo-rollouts-dashboard-ingress` | `rollouts.local` | `/` (`Prefix`) | none | `argo-rollouts-dashboard:3100` | `PathPrefix: /` -> `argo-rollouts-dashboard:3100` |
| 4 | `dev/belleshop-frontend-ingress` | `belleshop.local` | `/` (`Prefix`) | none | `belleshop-frontend-service:80` | `PathPrefix: /` -> `belleshop-frontend-service:80` |
| 5 | `dev/belleshop-api-ingress` | `belleshop.local`, `api.belleshop.local` | `/api(/|$)(.*)` and `/()(.*)` (`ImplementationSpecific`) | `use-regex: "true"`, `rewrite-target: /$2` | `belleshop-backend-service:5000` | See below — **no regex required** |

### Why BelleShop's API route does not need regex in `HTTPRoute`

In `ingress-nginx`, `nginx.ingress.kubernetes.io/rewrite-target` replaced the entire request URI with a literal string
unless regex capture groups were enabled (`use-regex: "true"` + `/api(/|$)(.*)` -> `/$2`). Because `belleshop-api-ingress`
put that annotation at the `Ingress` level, the second host rule (`api.belleshop.local`) had to use a dummy capture
group `/()(.*)` just so `/$2` preserved the path.

In Gateway API `v1` ([`HTTPRoute` specification](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1.HTTPRoute)):

1. `PathPrefix` matching is **segment-aware** by specification: `value: /api` matches `/api`, `/api/`, and
   `/api/products`, and never matches `/apikeys`.
2. The **Core** `URLRewrite` filter with `path.type: ReplacePrefixMatch` and `replacePrefixMatch: /` strips `/api` and
   leaves the rest of the path intact (`/api/products` -> `/products`, `/api` -> `/`).
3. On `api.belleshop.local`, `PathPrefix: /` forwards the path unchanged with no filter at all.

 Both rules use portable **Core** Gateway API features — no regular expressions and no vendor extension CRDs:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: belleshop-api
  namespace: dev
spec:
  parentRefs:
    - name: homelab-gateway
      namespace: nginx-gateway
  hostnames:
    - belleshop.local
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: belleshop-backend-service
          port: 5000
          weight: 100
        - name: belleshop-backend-canary
          port: 5000
          weight: 0
```

(`api.belleshop.local` can either be a second `HTTPRoute` `belleshop-api-host` or a second rule if headers/host match
are split; keeping `belleshop-api` as the route referenced by Argo Rollouts lets the canary plugin manage a single
`rules[0].backendRefs` list.)

### How Argo Rollouts canary routing changes

Today `belleshop-backend` (`belleshop-deploy` `base/backend-rollout.yaml`) uses `trafficRouting.nginx`, where Argo
Rollouts creates and mutates a shadow `<ingress>-canary` resource with `nginx.ingress.kubernetes.io/canary-weight`.

Gateway API builds weighted traffic splitting directly into `HTTPRoute.spec.rules[].backendRefs[].weight`. Argo Rollouts
supports this through the official traffic-router plugin
[`argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi`](https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi)
(current release [`v0.17.0`](https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/tag/v0.17.0)):

- **Controller setup (`homelab-platform`):**
  - Mount the pinned `linux-amd64` plugin binary into the `argo-rollouts` controller pod (via an initContainer from the
    pinned OCI image `ghcr.io/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi:v0.17.0` or Nexus proxy digest) and
    point `argo-rollouts-config` `ConfigMap` (`trafficRouterPlugins`) at the local binary path so the controller never
    downloads executables from GitHub at runtime.
  - Add RBAC for `ServiceAccount/argo-rollouts` on `gateway.networking.k8s.io` resources `httproutes` and `tcproutes`
    (`get`, `list`, `watch`, `patch`, `update`).
- **Rollout spec (`belleshop-deploy` `base/backend-rollout.yaml`):**
  ```yaml
  trafficRouting:
    plugins:
      argoproj-labs/gatewayAPI:
        httpRoute: belleshop-api
        namespace: dev
  ```

## Options considered (2026 landscape)

| Option | Current release (Oct 2026) | K8s 1.33 & Gateway API `v1` | Control / data plane split | Est. RAM on workers | Fit for this lab |
|---|---|---|---|---|---|
| **NGINX Gateway Fabric** ([docs](https://docs.nginx.com/nginx-gateway-fabric/), [repo](https://github.com/nginx/nginx-gateway-fabric)) | `v2.8.0` (NGINX OSS `1.31.7`, Gateway API `v1.6.3`) | Supported (`1.32+`); 100% Core + Extended `HTTPRoute` conformance | **Yes** (since 2.0): `nginx-gateway` control plane + per-`Gateway` NGINX OSS data-plane pod | ~100–140 MiB total | **Recommended.** Direct NGINX OSS successor to `ingress-nginx`; lowest memory among split-plane controllers; tested with Argo Rollouts Gateway API plugin |
| **Envoy Gateway** ([docs](https://gateway.envoyproxy.io/), [repo](https://github.com/envoyproxy/gateway)) | `v1.9.3` (Envoy `v1.39.x`, Gateway API `v1.6.1`) | Supported (`1.33–1.36`); full conformance | **Yes**: `envoy-gateway` controller + dynamically provisioned Envoy proxy pod | ~250–450 MiB total | Strong CNCF graduate, but Envoy + controller consumes ~2–3× the memory of NGINX OSS for five simple HTTP routes |
| **Traefik Proxy** ([docs](https://doc.traefik.io/traefik/providers/kubernetes-gateway/), [repo](https://github.com/traefik/traefik)) | `v3.7.17` (Gateway API `v1.5/v1.6`) | Supported; Core `HTTPRoute` conformance since v3.1 | **No**: single pod runs both the Kubernetes API watcher and the internet-facing proxy | ~80–120 MiB | Smallest pod count, but keeps the monolithic security model (`ServiceAccount` token with cluster read access inside the proxy pod) |
| **Istio Gateway / Ambient** ([docs](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/), [repo](https://github.com/istio/istio)) | `1.31.3` | Supported | **Yes** (`istiod` + Envoy gateway pod; ambient adds `ztunnel` DaemonSet) | ~350–600+ MiB | Overkill when we do not need mTLS mesh; ambient's per-node `ztunnel` taxes both 4 GB workers |
| **Cilium Gateway API** ([docs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/), [repo](https://github.com/cilium/cilium)) | `v1.20.4` | Supported (with Cilium CNI) | Embedded in Cilium Envoy DaemonSet + eBPF | N/A | **Ruled out.** Requires Cilium as the cluster CNI with `kube-proxy` replacement; our cluster runs Flannel |

### Why NGINX Gateway Fabric over Envoy Gateway and Traefik

1. **Control-plane / data-plane isolation (lesson from `ingress-nginx` CVE-2025-1974):**
   In `ingress-nginx` and in Traefik's single-pod architecture, the container parsing untrusted HTTP requests from the
   network also holds a Kubernetes `ServiceAccount` token that can read cluster `Secrets` and routes. NGINX Gateway
   Fabric `2.x` decouples the control plane (`nginx-gateway`, which watches the Kubernetes API and has no external
   `Service`) from the data plane (`nginx` + `nginx-agent`, which handles port 80/443 traffic and mounts **no**
   Kubernetes API credentials, receiving config over mTLS gRPC from the control plane).
2. **Memory headroom on 4 GB workers:**
   Both NGINX Gateway Fabric and Envoy Gateway provide control/data-plane separation, but NGINX OSS (`1.31.7`) +
   `nginx-agent` uses roughly half the memory of an Envoy proxy + `envoy-gateway` control plane. With `k8s-worker-1` and
   `k8s-worker-2` already at 50–57% memory after adding Kyverno, saving ~150–250 MiB matters.
3. **Operational familiarity:**
   Access logs, worker tuning, and upstream behaviour remain standard NGINX OSS, while all routing configuration moves to
   standard Gateway API `v1` (`GatewayClass`, `Gateway`, `HTTPRoute`, `ReferenceGrant`) with zero custom annotations.

## Decision

| Question | Choice | Why |
|---|---|---|
| Controller | **NGINX Gateway Fabric `v2.8.0`** (NGINX OSS data plane) in namespace `nginx-gateway` | Supported on Kubernetes 1.33, Gateway API `v1.6.3` conformant, split control/data plane, fits our 4 GB workers |
| Gateway API CRDs | Standard channel `v1.6.3` (`GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, `ReferenceGrant`), synced by Argo CD with `ServerSideApply=true` and `ServerSideDiff=true` | Matches NGF `v2.8.0`'s tested Gateway API bundle; `ServerSideDiff=true` avoids the CRD diff loop seen with Kyverno ([ADR 0012](0012-promotion-and-admission-control.md)) |
| Gateway topology | Single shared `Gateway` (`homelab-gateway` in `nginx-gateway`) with `allowedRoutes.namespaces.from: All` (or selector on labelled namespaces) | Mirrors the single `ingress-nginx` LoadBalancer (`192.168.1.240`); saves MetalLB IPs and avoids running multiple NGINX data-plane deployments |
| Route ownership | Platform `HTTPRoute` objects (`argocd`, `grafana`, `rollouts`) live in `homelab-platform` inside each service's namespace; BelleShop `HTTPRoute` objects (`belleshop-frontend`, `belleshop-api`) live in `belleshop-deploy` (`namespace: dev`) | App routes stay in the app config repo alongside the `Rollout` and `Service` they target; no cross-namespace `ReferenceGrant` needed because each `HTTPRoute` lives in the same namespace as its `Service` |
| Data-plane sizing | `NginxProxy` resource pinned to `1` replica with explicit CPU/memory requests and limits | Prevents unexpected scaling on a 2-worker homelab cluster |
| Canary traffic router | `argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi` `v0.17.0`, loaded via initContainer (no runtime internet download) | Official Argo Rollouts Gateway API integration; keeps air-gapped/pinned runtime posture |
| Cutover method | Parallel bring-up on MetalLB `.244`, smoke-test all 5 routes + a canary rollout via `--resolve` / `/etc/hosts`, then move `.240` to `homelab-gateway` and remove `ingress-nginx` | Instant rollback before `.240` moves; zero-guesswork verification of every route and canary step |

## Not now

- **TLS termination on `homelab-gateway` (`HTTPS` listeners / `cert-manager`):** All five current Ingresses are HTTP-only on `.local` names; adding TLS on the cluster gateway is a separate step from replacing `ingress-nginx`.
- **Replacing Flannel with Cilium:** Flannel is stable on 1.33 and does not need to change to adopt Gateway API.
- **Mesh / east-west mTLS (Istio Ambient / Linkerd):** Not needed for a single two-tier application (`frontend` -> `backend` -> `mysql`).
- **Experimental Gateway API CRDs (`TCPRoute`, `UDPRoute`, `TLSRoute`):** All five services are HTTP; the Standard channel CRDs are sufficient.

## Consequences

- `ingress-nginx` and its two admission webhook `Job` workarounds (`Force=true,Replace=true`, removed `ttlSecondsAfterFinished`) are deleted from `homelab-platform` once cutover completes.
- `argo-rollouts` gains an initContainer and RBAC for `gateway.networking.k8s.io/httproutes`.
- NGINX Gateway Fabric `2.x` dynamically creates the data-plane `Deployment` and `LoadBalancer` `Service` (`homelab-gateway-nginx`) owned by the `Gateway` resource; MetalLB assigns the VIP configured via `Gateway.spec.addresses` (`192.168.1.240`).
- Every route uses portable `gateway.networking.k8s.io/v1` `HTTPRoute` specs with no controller-specific annotations; switching to Envoy Gateway in the future would only require changing `gatewayClassName` and the controller Application.

## Rollout plan

| Step | Action | Verification / Rollback |
|---|---|---|
| 1. Vendor Gateway API CRDs + NGINX Gateway Fabric `v2.8.0` | Add Gateway API `v1.6.3` standard CRDs and NGF `v2.8.0` under `k8s/platform/nginx-gateway/` in `homelab-platform` (`ServerSideApply=true`, `ServerSideDiff=true`). Pin images through Nexus or upstream digest | `kubectl get gatewayclass nginx` reports `Accepted=True`; `ingress-nginx` on `.240` is untouched |
| 2. Provision `homelab-gateway` on staging VIP `192.168.1.244` | Create `NginxProxy` (1 replica, resource requests/limits) and `Gateway/homelab-gateway` requesting address `192.168.1.244` from MetalLB | `kubectl -n nginx-gateway get gateway homelab-gateway` shows `Programmed=True`, `ADDRESS=192.168.1.244` |
| 3. Add `HTTPRoute` resources alongside existing `Ingress` objects | Add `HTTPRoute` manifests for `argocd.local`, `grafana.local`, `rollouts.local` in `homelab-platform`, and `belleshop.local` (frontend + `/api` with `ReplacePrefixMatch: /`) and `api.belleshop.local` in `belleshop-deploy` | Existing `Ingress` objects on `.240` keep serving traffic; test all 15 HTTP checks from `INGRESS-UPGRADE-NOTES.md` against `192.168.1.244` (`curl --resolve <host>:80:192.168.1.244`) and verify identical status codes |
| 4. Enable Argo Rollouts Gateway API plugin and switch `belleshop-backend` | Add `rollouts-plugin-trafficrouter-gatewayapi` `v0.17.0` + `httproutes` RBAC to `argo-rollouts` in `homelab-platform`; update `belleshop-deploy` `base/backend-rollout.yaml` from `trafficRouting.nginx` to `trafficRouting.plugins["argoproj-labs/gatewayAPI"]` | Trigger a rollout in `dev`; verify `HTTPRoute/belleshop-api` `backendRefs` weights step `20 -> 50 -> 100` and `AnalysisRun` succeeds |
| 5. Cut over VIP `192.168.1.240` and remove `ingress-nginx` | Remove the five `Ingress` resources, remove the `ingress-nginx` Application (releasing `.240`), and update `Gateway/homelab-gateway` `spec.addresses` from `192.168.1.244` to `192.168.1.240` | Re-run all 15 HTTP checks against `.240` (`argocd.local`, `grafana.local`, `rollouts.local`, `belleshop.local`, `api.belleshop.local`). Rollback: revert the Git commit in `homelab-platform` |

## References

- Kubernetes Blog — [`ingress-nginx` retirement announcement (Nov 2025 / Mar 2026 EOL)](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)
- Kubernetes Gateway API — [`HTTPRoute` v1 specification & `URLRewrite` (`ReplacePrefixMatch`)](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1.HTTPURLRewriteFilter)
- NGINX Gateway Fabric — [Documentation](https://docs.nginx.com/nginx-gateway-fabric/) and [`v2.8.0` technical specifications](https://github.com/nginx/nginx-gateway-fabric/blob/v2.8.0/README.md)
- Envoy Gateway — [Release compatibility matrix (`v1.9.x`)](https://gateway.envoyproxy.io/docs/install/matrix/)
- Traefik Proxy — [Kubernetes Gateway API provider documentation (`v3.x`)](https://doc.traefik.io/traefik/providers/kubernetes-gateway/)
- Istio — [Kubernetes Gateway API task guide](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/)
- Cilium — [Gateway API prerequisites (`kubeProxyReplacement` + Cilium CNI)](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)
- Argo Rollouts — [`rollouts-plugin-trafficrouter-gatewayapi` (`v0.17.0`)](https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi)

## Changes made during rollout (2026-10-31)

- Staging address is `192.168.1.244`, not `.241`: `.240`–`.243` are taken by ingress-nginx, Argo CD, Grafana and the
  Rollouts dashboard LoadBalancers.
- Gateway API CRDs: the standard `v1.6.3` bundle, exactly what NGF v2.8.0's `config/crd/gateway-api/standard` pins
  (its release notes mention an earlier bump to 1.6.2).
- Both NGF images are pinned by digest: the control plane through kustomize `images`, the data plane through the
  `NginxProxy` `tag` field (`2.8.0@sha256:…`).
- The cert-generator `Job` gets the ingress-nginx treatment (no TTL, `Force=true,Replace=true`) to avoid the self-heal loop.
