# Runbook: public personal-site monitoring

Alerts for the Cloudflare edge, public-gateway data plane, personal-site prod,
and the public-path blackbox probes. Connector/gateway background:
[edge-public.md](edge-public.md). Promoter job: [ci-platform.md](ci-platform.md).

Critical alerts use the existing Alertmanager `severity=critical` email route.
Warnings stay on the root `null` receiver (UI only), same as BelleShop latency.

## Owner steps before the probes can fire

1. Probe **targets** go to OpenBao (never git):

   ```sh
   scripts/openbao-breakglass.sh root-run public-site-probes --dry-run
   scripts/openbao-breakglass.sh root-run public-site-probes
   ```

   Hidden prompts: apex (expect 200) and staging (expect 302). Shape check is
   local (`https://` + DNS hostname, no raw IPs) and dies before minting a root
   token. Writes ACL `public-site-probes-read`, role `public-site-probes` bound
   to `monitoring/eso-public-site-probes`, KV `secret/monitoring/public-site-probes`.
   Re-run skips unless `--overwrite`.

2. Wait for ExternalSecret `public-site-probe-targets` in `monitoring` to merge
   `apex.json` / `staging.json`. Prometheus file_sd picks them up (jobs
   `public-site-apex` / `public-site-staging`). Until then the bootstrap Secret
   is `[]` and the down alerts have no series (they do **not** page).

3. Promoter paging is **not** Prometheus. JCasC overwrites UI-created
   credentials. Put the healthchecks ping URL (one line) in gitignored
   `private/promoter-watchdog-url`, then:

   ```sh
   cd ansible && ansible-playbook playbooks/jenkins.yml
   ```

   That copies it to `/etc/jenkins/secrets/promoter-watchdog-url` and the
   `promoter-watchdog-url` string credential. On success the job GETs the URL;
   on **3 consecutive failures** it GETs `{url}/fail`. Missing file skips the
   credential (build still fails for the real error). Never print the URL.

## CloudflaredReplicasLow (critical, 5m)

**Means:** `kube_deployment_status_replicas_available{namespace="edge-public",deployment="cloudflared"} < 2`.
Want 2 (anti-affinity across workers). Live 2026-11-09: 2.

**Do:**

1. `kubectl -n edge-public get deploy,pods,events`
2. If ImagePull/ESO: Secret `cloudflared` / ExternalSecret, then
   [edge-public.md](edge-public.md) token steps
3. If one node is dead: [monitoring.md](monitoring.md) HomelabKubeNodeNotReadyFast

## CloudflaredTunnelDisconnected (critical, 5m) / CloudflaredTunnelHADegraded (warning, 5m)

**Means:** live metric `cloudflared_tunnel_ha_connections` (HELP: "Number of active
ha connections"). Healthy value **4** per replica (verified 2026-11-09 on
`:2000/metrics`). 0 pages; 1–3 warns.

**Do:**

1. Confirm ServiceMonitor `cloudflared` is scraped (`up{job="cloudflared"}`)
2. `kubectl -n edge-public logs deploy/cloudflared --tail=100`
3. Cloudflare dashboard: connector registered, not overloaded
4. NetworkPolicy: `edge-public-cloudflare-egress` still 443/7844 with RFC1918 except'd

## PublicGatewayDataPlaneDown (critical, 2m)

**Means:** `kube_deployment_status_replicas_available{namespace="nginx-gateway",deployment="public-gateway-nginx"} < 1`.
Live 2026-11-09: 1 replica.

**Do:**

1. `kubectl -n nginx-gateway get deploy,pods public-gateway-nginx`
2. Origin hop is HTTP :80 from cloudflared only ([edge-public.md](edge-public.md))
3. NGF control plane `nginx-gateway` can be up while this data plane is down —
   do not stop at the controller pod

## PersonalSiteProdUnavailable (critical, 2m)

**Means:** `kube_deployment_status_replicas_available{namespace="personal-site-prod",deployment="personal-site"} < 1`.
Live 2026-11-09: Deployment `personal-site`, 1 replica.

**Do:**

1. `kubectl -n personal-site-prod get deploy,pods,httproute`
2. Image digest from apps-deploy overlay; promoter may have opened a staging PR
   that was not promoted ([ci-platform.md](ci-platform.md))
3. Tenant netpol `tenant-public-gateway-ingress` must still admit
   `public-gateway-nginx` on 8080

## PublicSiteApexDown / PublicSiteStagingDown (critical, 2m)

**Means:** `probe_success{job="public-site-apex"}` or `...staging` is 0. Modules
`http_2xx_public` (200) and `http_302_public` (302), `follow_redirects: false`,
public CAs, through the **real public path** (blackbox internet :443).

**Do:**

1. Confirm file_sd is non-empty: Prometheus targets for those jobs
2. Blackbox pods + `monitoring-blackbox-public-egress` (443, RFC1918 except'd)
3. Work inward: Cloudflare dashboard → cloudflared HA → public-gateway →
   personal-site Deployment
4. Staging **should** be 302 (Access / login). A 200 here is a failed probe

These alerts are silent when the OpenBao URLs have not been written yet (no
series). That is intentional so merge-before-breakglass does not page.

## Network policy notes

- Prometheus scrape of cloudflared :2000: existing pod-CIDR egress + new
  `edge-public-metrics-ingress`
- Blackbox public GET: **new** `monitoring-blackbox-public-egress` only.
  Prometheus still has **no** internet egress
- Do not widen either rule to all ports or to RFC1918
