# oauth2-proxy (Prometheus and Alertmanager UIs)

Argo Application `oauth2-proxy` (declared in `k8s/platform/apps/oauth2-proxy.yaml`,
picked up by `platform-root` which syncs the whole `k8s/platform/apps` directory).

Chart 10.7.1, image `quay.io/oauth2-proxy/oauth2-proxy:v7.15.5` by digest. HTTPRoutes
and NetworkPolicies that retarget the Gateway live in the `monitoring` and
`nginx-gateway` apps so existing objects keep their owners.
