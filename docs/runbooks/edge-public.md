# Runbook: public edge (`edge-public` + `public-gateway`)

Why and what: [ADR 0019](../adr/0019-internal-developer-platform.md) D7. Public apps reach
the internet through a Cloudflare Tunnel. Admin UIs stay on `homelab-gateway` (MetalLB
`.240`) and have no NetworkPolicy path from the tunnel.

This repo is public. **Do not commit public hostnames, the tunnel token, or WAN addresses.**
The hostname → origin map lives only in the Cloudflare dashboard (remotely-managed tunnel).

## Objects in git

| Piece | Where |
|---|---|
| Gateway `public-gateway` + NginxProxy `public-gateway-proxy-config` (`service.type: ClusterIP`) | `k8s/platform/nginx-gateway/` |
| Connector Deployment (2 replicas, anti-affinity, digest-pinned) | `k8s/platform/edge-public/` |
| Argo Application `edge-public` | `k8s/platform/apps/edge-public.yaml` |
| Tenant extra ingress from `public-gateway-nginx` | `k8s/tenants/_kit/public-ingress/` |

NGF 2.8.0 creates one data-plane Service per Gateway. The class NginxProxy
(`nginx-gateway-proxy-config`) is LoadBalancer. The public Gateway's
`spec.infrastructure.parametersRef` points at a second NginxProxy whose
`spec.kubernetes.service.type` is `ClusterIP` (CRD enum; default is LoadBalancer). NGF
merges Gateway over GatewayClass; that is the supported way to keep MetalLB off this
Service. Do **not** set `spec.addresses` — NGF copies those to `externalIPs`, which
kube-proxy accepts and MetalLB never announces (ADR 0013).

Expected live names (NGF convention, same as `homelab-gateway` → `homelab-gateway-nginx`):
Deployment/Service `public-gateway-nginx`, pod label `app.kubernetes.io/name=public-gateway-nginx`.

## HTTP vs HTTPS on the cloudflared → gateway hop

Listener is **HTTP :80**. Cloudflare terminates public TLS at the edge. The hop is
ClusterIP-only; NetworkPolicy admits only `edge-public` pods labelled `cloudflared` on
port 80 — no `192.168.1.0/24`.

ADR D7 asked for HTTPS with the lab CA as cloudflared `caPool`. That origin-TLS setting
is **UNVERIFIED** against cloudflared `2026.10.7` from this repo, and would need a cert
Secret on `public-gateway`. Revisit if the extra hop must be encrypted.

## Owner steps (order)

### 1. Cloudflare dashboard (nothing in git)

1. Create a **remotely-managed** tunnel. On the "install connector" page copy ONLY the
   token after `--token` (starts with `eyJ`). Do **not** run the shown
   `cloudflared service install` command on any machine: the two cloudflared pods in
   `edge-public` are the connectors. Store the token only in the password manager until step 2.
2. Public DNS for each hostname: proxied CNAME to the tunnel, **not** to `.240` or any
   LAN address.
3. WAF / rate limits / Always Online as needed. Cloudflare Access in front of every
   `-staging` hostname.
4. Public hostname origin: `http://public-gateway-nginx.nginx-gateway.svc:80`. The map
   stays in the dashboard.

### 2. OpenBao (before or with the Argo sync)

No standing admin token. Writes go through break-glass:

```sh
scripts/openbao-breakglass.sh root-run cloudflared-token --dry-run   # plan only
scripts/openbao-breakglass.sh root-run cloudflared-token             # 2 hidden shares, then hidden token
```

Shape check is local: the token is one standard-base64 blob of JSON `{"a","t","s"}`
(account tag, tunnel UUID, secret), not a JWT. It is decoded and checked without printing.
A bad paste dies **before** minting a root token. The value is never printed (`stored (N chars)`).
Re-run skips an existing secret unless `--overwrite`.

What the run writes:

- ACL policy `cloudflared-read` (read `secret/data/platform/cloudflared` only)
- Kubernetes auth role `cloudflared` bound to `edge-public/eso`, TTL 1h
- KV `secret/platform/cloudflared` with key `tunnel_token`

### 3. Merge this branch

Argo CD picks up `edge-public` and the extra objects in `nginx-gateway`. ESO is unready
until step 2 has run; that is expected. `CreateNamespace=false`: the Namespace manifest
carries PSA `restricted`.

### 4. Public tenant overlay

On the platform PR for that app:

1. Set Namespace label `homelab.arpa/exposure: public` (replace `internal`).
2. **Do not** add `homelab.arpa/gateway-routes: "true"` — that label admits the namespace
   to `homelab-gateway`.
3. Include component `k8s/tenants/_kit/public-ingress` (ingress from
   `public-gateway-nginx` on 8080, post-DNAT).
4. HTTPRoute `parentRefs` the Gateway `public-gateway` in namespace `nginx-gateway`
   (that object lives in `apps-deploy`, which may name public hosts; this public repo
   does not).

Internal tenants keep the kit base policy (`homelab-gateway-nginx` only).

## Prove (after sync; limited kubeconfig)

```sh
# ClusterIP, not LoadBalancer; no LAN IP
kubectl -n nginx-gateway get svc public-gateway-nginx -o jsonpath='{.spec.type}{"\n"}{.spec.clusterIP}{"\n"}{.status.loadBalancer}'

# Connector up (after the token Secret exists)
kubectl -n edge-public get deploy,pods

```

### Isolation test (admin kubeconfig, run on master)

```sh
ssh tunsadmin@192.168.1.90 'bash -s' < scripts/edge-isolation-test.sh
```

Three short-lived probe pods wear the labels of `cloudflared` and `public-gateway-nginx`
(so the same NetworkPolicies select them) plus one unlabelled probe, and every "blocked"
check has an "allowed" control next to it. A probe that is not Running voids its checks
instead of counting as blocked. The cloudflared look-alike tolerates the apps-pool taint:
the real pods' required anti-affinity repels it from workernode1/2.

**Recorded 2026-11-09: 22/22 PASS.** Tunnel: 2 connectors (workernode1, workernode2),
4 QUIC connections each.

| From | Allowed (controls) | Blocked |
|---|---|---|
| cloudflared | public-gateway Service + pod :80, internet :443, DNS | admin gateway pod and `.240`, argocd-server, grafana, apiserver `.90:6443`, OpenBao `.95`, router, internet on other ports |
| public-gateway | NGF control plane :8443 | argocd-server, grafana, internal tenant (demo-staging), OpenBao, internet |
| into public-gateway | cloudflared | unlabelled pod in `default`, the master host (LAN) |

First runs caught two harness bugs before they could hide a result: the look-alike could
not schedule (anti-affinity, above), and a rerun raced the previous run's terminating
probes, so two "blocked" checks passed against pods that no longer existed. The failed
controls exposed it; the script now waits for old probes and checks each probe is alive.

## Rollback

- Revert the git change; Argo prune removes `edge-public` and the extra Gateway/NginxProxy/NetPols.
- `bao delete secret/metadata/platform/cloudflared`
- `bao delete auth/kubernetes/role/cloudflared`
- `bao policy delete cloudflared-read`
- Delete the Cloudflare tunnel and DNS in the dashboard.

## Image pin

`docker.io/cloudflare/cloudflared:2026.10.7@sha256:4955524aeaa379e154023d5a027c250f7b35041a2e7e950cf13f144bc9b9c5ba`
(Docker Hub tag index digest, 2026-11-08). Namespace is not Kyverno-admission-enforced
(platform add-on, same as falco). Mirror into `registry.home.arpa/platform/` later if
the exemption should go away.
