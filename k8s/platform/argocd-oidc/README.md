# Argo CD OIDC (owner-applied, not Argo-synced)

Argo CD's own ConfigMaps are out of git ([ADR 0008](../../../docs/adr/0008-argocd-app-of-apps-platform.md)).
This directory is the **intended** `argocd-cm` / `argocd-rbac-cm` merge for native Gitea OIDC
([ADR 0016](../../../docs/adr/0016-oidc-sso-admin-uis-gitea.md) step 2). It is **not** an Application
source: `cluster-config` only syncs `k8s/platform/cluster-config`.

Apply with `scripts/argocd-oidc-apply.sh` (merge-patch; never replace the live ConfigMaps, which
already carry `resource.exclusions` / ignore-updates). The client id and secret stay out of git:
they are prompted (or `ARGOCD_OIDC_CLIENT_ID` / `ARGOCD_OIDC_CLIENT_SECRET`) and patched into
`argocd-secret` keys `oidc.gitea.clientID` and `oidc.gitea.clientSecret` via stdin.

`argocd-tls-certs-cm` already pins the Gitea Caddy root for **git** TLS. OIDC HTTP (discovery,
token, JWKS) uses `oidc.config.rootCA` in v3.5.1, not that ConfigMap.
