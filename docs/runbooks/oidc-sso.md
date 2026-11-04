# Runbook: OIDC SSO for the admin UIs (ADR 0016)

Owner-only. This runbook executes [ADR 0016](../adr/0016-oidc-sso-admin-uis-gitea.md): shared prep (step 0),
Grafana (step 1), Argo CD (step 2), and oauth2-proxy for the Prometheus/Alertmanager UIs (step 3).
Nothing in this runbook is agent-applied to the cluster.

## What already exists (verified 2026-11-03)

- Gitea 1.27.3 answers OIDC discovery at `https://gitea.home.arpa/.well-known/openid-configuration`
  (issuer `https://gitea.home.arpa`, RS256, PKCE S256, scopes `openid profile email groups`).
- `gitea.home.arpa` is signed by the Gitea Caddy root (`ansible/files/ca/gitea-caddy-root.crt`), NOT the lab root:
  `openssl verify -CAfile ansible/files/ca/gitea-caddy-root.crt <leaf>` OK, lab root fails error 20. That root is
  shipped into `monitoring` as ConfigMap `gitea-caddy-root` and mounted at `/etc/grafana/ca/gitea-caddy-root.crt`.
- In-cluster path from the grafana pod (read-only admin exec, the one allowed, 2026-11-03):
  `gitea.home.arpa` resolves via CoreDNS to `192.168.1.97`, and HTTPS `:443` timed out (curl error 28) because the
  monitoring default-deny had no egress rule to `.97` yet. The `monitoring-grafana-oidc-egress` netpol in
  `k8s/platform/monitoring/manifests/netpol-allow.yaml` closes exactly that gap.

## Step 0 — shared prep (you, Gitea UI + OpenBao; no cluster change)

1. **Org and team.** In the Gitea UI create org `homelab` and team `platform-admins`
   (lowercase: the `groups` claim carries `org.Name + ":" + team.LowerName`, and every mapping in ADR 0016 uses the
   literal `homelab:platform-admins`). Put your account in the team.
2. **Four OAuth2 applications** (Site Administration → Integrations → OAuth2 Applications, confidential clients),
   one per consumer so a leaked secret revokes only that consumer (ADR 0016 decision 1):

   | Consumer | Redirect URI |
   |---|---|
   | `grafana` | `https://grafana.apps.home.arpa/login/generic_oauth` |
   | `argocd` | `https://argocd.apps.home.arpa/auth/callback` |
   | `oauth2-proxy-prometheus` | `https://prometheus.apps.home.arpa/oauth2/callback` |
   | `oauth2-proxy-alertmanager` | `https://alertmanager.apps.home.arpa/oauth2/callback` |

   Gitea shows the client secret once; keep the tab open for step 3.
3. **Store the secrets in OpenBao**, once per consumer, with ONE command that keeps the root token on sectools:

   ```bash
   scripts/openbao-breakglass.sh root-run oidc grafana   # and later: argocd, oauth2-proxy-prometheus, oauth2-proxy-alertmanager
   ```

   In one ssh session it prompts (all hidden): 2 unseal shares (the store's threshold: 3 shares / t=2), the client
   id, the client secret. On sectools it mints the short-lived root token, writes policy `oidc-read` (read-only on
   the ESO-consumed `secret/data/oidc/*` paths; `oidc/argocd` is excluded because you read that one yourself over
   the admin SSH path), the Kubernetes auth role `oidc` for ServiceAccount `monitoring/eso-oidc`
   (SecretStore `openbao-oidc`) and the KV secret, generates the 32-byte cookie secret itself for the
   oauth2-proxy-* consumers (it never touches the Mac), verifies the key set, and always revokes the token.
   `--dry-run` prints the flow; `--overwrite` rotates (rotate the Gitea app secret first). Undo: the
   `root-run oidc` undo block in the header of `scripts/openbao-breakglass.sh`.

   Why not a Mac-side script with `BAO_TOKEN`: the root token never reaches the Mac, and minting one from the Mac
   is impossible anyway — OpenBao's listener binds `127.0.0.1` on sectools and Caddy 403s `/v1/sys/generate-root*`
   from the network (both verified 2026-11-03: `https://bao.home.arpa` answers health 200 from the Mac, but
   generate-root answers 403).

## Step 1 — Grafana (merged in git; Argo CD syncs it)

What shipped in git (all consumed by the Argo `monitoring` app, no extra include step needed — the app sources the
whole `k8s/platform/monitoring/manifests` directory and the values file):

- `k8s/platform/monitoring/values.yaml`: the `grafana.ini.auth.generic_oauth` section (Gitea URLs from the live
  discovery doc, `use_pkce`, `tls_client_ca` at the ConfigMap mount, `allowed_groups` gating on org `homelab`,
  `role_attribute_path` mapping `homelab:platform-admins` → Admin, org members → Viewer) and the two
  `GF_AUTH_GENERIC_OAUTH_*` env refs.
- `manifests/gitea-caddy-root-cm.yaml` (ConfigMap `gitea-caddy-root`, byte-identical to the vendored root).
- `manifests/eso-oidc-sa.yaml` + `manifests/secretstore-openbao-oidc.yaml` (per-path least-privilege store;
  `eso-tokenreview` binding in `k8s/platform/cluster-config/`).
- `manifests/externalsecret-grafana-oidc.yaml` (Secret `monitoring/grafana-oidc`).
- `manifests/netpol-allow.yaml`: `monitoring-grafana-oidc-egress` (grafana pods → `192.168.1.97/32:443`).

**Ordering that matters**: the env refs are `optional: true`, so this merge is safe to apply BEFORE you store the
OpenBao secret. Until then: ESO logs the ExternalSecret as unready (expected), and Grafana runs with SSO broken
while the local admin login keeps working. Proven, not assumed (2026-11-03): `grafana/grafana:13.1.3` was run in
docker with `GF_AUTH_GENERIC_OAUTH_ENABLED=true` and EMPTY client id/secret plus the Gitea URLs and a mounted
`tls_client_ca` — it starts clean (`/api/health` 200, no error/warn lines in the log) and `/login/generic_oauth`
still answers 302: with an empty id Grafana substitutes its default `client_id=some_id`, so a pre-secret login
fails visibly at Gitea's authorize page (unregistered client), never at Grafana startup.

**The pod restart — when and why**: the env var from the optional `secretKeyRef` is read only at pod start. A pod
that started before the `grafana-oidc` Secret existed keeps an empty client id/secret until it restarts. So after
the Secret first syncs (check: `ssh tunsadmin@192.168.1.90 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf
-n monitoring get secret grafana-oidc'` — the restart does nothing useful before it exists), restart the
deployment once, owner-run, one command via the Master path:

```bash
ssh Master 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n monitoring rollout restart deploy/prometheus-stack-grafana'
```

If you store the secret before merging and the Secret is in place before the new pod starts, no restart is needed;
the command above is the deterministic way to guarantee the env is picked up either way.

**Owner sequence, one command each, in order**: create the Gitea app (UI) → `scripts/openbao-breakglass.sh root-run
oidc grafana` (prompts: 2 unseal shares, client id, client secret) → merge the PR (Argo syncs the manifests,
values, netpol and ExternalSecret) → check the `grafana-oidc` Secret exists → the restart above → the proofs
below.

### Proofs (ADR 0016 step 1)

1. **In-cluster TLS path, after the netpol exists** (the step 0 remainder; read-only, admin SSH path):

   ```bash
   ssh tunsadmin@192.168.1.90 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf \
     -n monitoring exec <grafana-pod> -c grafana -- \
     curl -sS --cacert /etc/grafana/ca/gitea-caddy-root.crt \
     -o /dev/null -w "%{http_code}\n" https://gitea.home.arpa/.well-known/openid-configuration'
   ```

   Expect `200`. Before the netpol this same call timed out (curl 28); if it still times out, the netpol is not
   applied or the agent is down — stop here, everything else depends on this path.
2. **Login redirect**: `curl -sSI https://grafana.apps.home.arpa/login/generic_oauth | head -5` → `302` with a
   `Location` pointing at `https://gitea.home.arpa/login/oauth/authorize?...`.
3. **Browser login**: log in via Gitea; land in Grafana; Settings shows the account, org role Admin (you are in
   `platform-admins`).
4. **Local admin still works**: the login page shows both options; the local admin is unchanged (`grafana-admin`
   Secret).
5. **Token exchange in the logs**: `kubectl -n monitoring logs deploy/prometheus-stack-grafana | grep -i oauth`
   shows token/userinfo calls to `192.168.1.97` succeeding.

### Rollback

`git revert` the step 1 commit and let Argo sync (or the restart command above to drop the OIDC env quickly).
Grafana returns to local-admin-only; nothing else changed. Optionally remove the OpenBao side with the
`root-run oidc` undo block in the header of `scripts/openbao-breakglass.sh`.

## Step 2 — Argo CD (owner-applied; not Argo-synced)

Live (2026-11-04, read-only): `quay.io/argoproj/argocd:v3.5.1`, pod `argocd-server-755b4b6b89-892hf`.
`argocd-cm` has resource customizations/exclusions only — **no `url`, no `oidc.config`**. `argocd-rbac-cm`
data is empty. `argocd-secret` keys: `admin.password`, `admin.passwordMtime`, `server.secretkey`.
`dex-server` is Running (`ghcr.io/dexidp/dex:v2.45.0`) and stays; native OIDC skips Dex when
`oidc.config` is set. `argocd-server` already has egress to `192.168.1.97:443`.
`argocd-tls-certs-cm` already has the Gitea Caddy root for **git** TLS; OIDC HTTP still needs
`oidc.config.rootCA` (PEM, not a volume).

What shipped in git (path `k8s/platform/argocd-oidc/` is **not** an Application source;
`cluster-config` only syncs `k8s/platform/cluster-config`):

- `argocd-cm.yaml` / `oidc.config.yaml`: merge keys `url: https://argocd.apps.home.arpa`,
  `admin.enabled: "true"`, `oidc.config` with Gitea issuer, `$oidc.gitea.clientID` /
  `$oidc.gitea.clientSecret`, scopes including `groups`, `enablePKCEAuthentication: true`,
  `rootCA` PEM from `ansible/files/ca/gitea-caddy-root.crt`.
- `argocd-rbac-cm.yaml`: `policy.default: ""`, `scopes: '[groups]'`,
  `g, homelab:platform-admins, role:admin` and `g, homelab, role:readonly`.
- `scripts/argocd-oidc-apply.sh`: `--dry-run`, apply, `--rollback`. Backups go to
  `~/homelab-platform/private/argocd-backup-<ts>/` (gitignored, 0600). Secret patch is stdin
  (`--patch-file=/dev/stdin`). No `kubectl rollout`.

Grafana lessons this step must not repeat: set `url` (redirect is `url` + `/auth/callback`);
`rootCA` is PEM in the ConfigMap string, not a mount; there is no `groups_claim_path` on v3.5.1
(unknown keys are not a Grafana-style silent ignore here — we simply do not invent keys);
patch the Secret **before** the `oidc.config` that references it (the script does secret then CMs).

**Owner sequence, in order:**

1. Gitea OAuth2 app `argocd` with redirect `https://argocd.apps.home.arpa/auth/callback` (step 0).
2. Store it: `scripts/openbao-breakglass.sh root-run oidc argocd` (2 unseal shares, client id, client
   secret). `oidc-read` **excludes** `secret/data/oidc/argocd`; you read that value yourself when the
   apply script prompts.
3. `scripts/argocd-oidc-apply.sh --dry-run` — prints the merge keys and `kubectl diff` of the two
   ConfigMaps. Expect `url`, `admin.enabled`, `oidc.config` added; existing `resource.*` keys kept.
4. `scripts/argocd-oidc-apply.sh` — confirm OpenBao, paste id+secret (hidden). Wait for Ready.
5. Proofs below. If wrong: `scripts/argocd-oidc-apply.sh --rollback`.

v3.5.1 restarts the API server in-process on oidc/url changes, but that is NOT enough: Live 2026-11-04: the in-process restart rebuilds the login handler (it trusted the Gitea root and redirected fine) but NOT the session manager's HTTP client, built at pod start without rootCA, so every session check failed with `x509: certificate signed by unknown authority` and the browser bounced back to /login. A `kubectl rollout restart deploy/argocd-server` fixed it.
The apply script now does the rollout restart itself (only the UI/API pod; syncing runs in the
application controller and is not affected).

### Proofs (ADR 0016 step 2)

1. **Login redirect** (from the Mac, `curl -q`):

   ```bash
   curl -q -sSI https://argocd.apps.home.arpa/auth/login
   ```

   Expect `302` or `303` with `Location` to `https://gitea.home.arpa/login/oauth/authorize` and
   `redirect_uri=https://argocd.apps.home.arpa/auth/callback`. A redirect to localhost means `url`
   did not take (the Grafana `root_url` failure mode).

2. **Browser login**: Gitea → Applications list; you can sync (you are in `homelab:platform-admins`).
3. **Local admin still works**: username `admin` + `argocd-secret` `admin.password` hash (break-glass).
4. **Logs** (admin SSH): `oidc config modified. restarting` / `url modified. restarting`, then Ready;
   JWKS/token against `192.168.1.97`, no PEM-append warning (`failed to append certificates from PEM`).
5. **Deny path** (needs a throwaway Gitea account with no org): login succeeds, UI is empty
   (`policy.default` is `""`); delete the account afterwards.

### Rollback

```bash
scripts/argocd-oidc-apply.sh --rollback
# or BACKUP_DIR=~/homelab-platform/private/argocd-backup-<ts> scripts/argocd-oidc-apply.sh --rollback
```

`kubectl replace` of the three backed-up objects. Dex is untouched. Optionally remove the OpenBao
side with the `root-run oidc` undo block in `scripts/openbao-breakglass.sh`.

## Step 3 — oauth2-proxy (Prometheus + Alertmanager UIs)

Do **not** merge this until both OpenBao records exist. The HTTPRoutes move off prometheus/alertmanager
onto a proxy whose Secret is required (not optional): merge-first would 502 both UIs.

**Owner sequence, one command each, in order:**

1. Gitea OAuth2 apps (confidential), exact redirect URIs:

   | Consumer | Redirect URI |
   |---|---|
   | `oauth2-proxy-prometheus` | `https://prometheus.apps.home.arpa/oauth2/callback` |
   | `oauth2-proxy-alertmanager` | `https://alertmanager.apps.home.arpa/oauth2/callback` |

2. Store them (cookie secret is generated on sectools, never on the Mac):

   ```bash
   scripts/openbao-breakglass.sh root-run oidc oauth2-proxy-prometheus
   scripts/openbao-breakglass.sh root-run oidc oauth2-proxy-alertmanager
   ```

   Keys written: `client_id`, `client_secret`, `cookie_secret`. `oidc-read` already lists both paths.

3. Merge the PR. Argo apps that move: `oauth2-proxy` (new, via `platform-root` + `k8s/platform/apps/oauth2-proxy.yaml`),
   `monitoring` (HTTPRoutes + netpols), `nginx-gateway` (data-plane egress `:4180` instead of `:9090`/`:9093`).
4. Proofs below.

v7.15.5 keys used (from `pkg/apis/options`, tag v7.15.5 — no invented names): `provider`,
`oidc-issuer-url`, `oidc-groups-claim`, `code-challenge-method`, `scope`, `provider-ca-file`,
`allowed-group`, `email-domain`, `redirect-url`, `cookie-secure`, `cookie-name`,
`reverse-proxy`, `real-client-ip-header`, `trusted-proxy-ip`, `upstream`. CA is a ConfigMap
**directory** mount (`/etc/oauth2-proxy/ca/gitea-caddy-root.crt`). Prometheus allows `homelab`;
Alertmanager allows only `homelab:platform-admins`.

### Proofs (ADR 0016 step 3)

A redirect is not a login (Argo CD step 2: `/auth/login` redirected, then the session check failed).
Every proof below includes a **follow-up request with the session cookie**.

1. **Unauthenticated redirect** (`curl -q`):

   ```bash
   curl -q -sSI https://prometheus.apps.home.arpa/
   curl -q -sSI https://alertmanager.apps.home.arpa/
   ```

   Expect 302/303 to `https://gitea.home.arpa/login/oauth/authorize` with
   `redirect_uri=https://prometheus.apps.home.arpa/oauth2/callback` (and the alertmanager host
   on the other). Localhost in `redirect_uri` means `redirect-url` did not take — rollback.

2. **Browser, org admin:** Gitea login as a `homelab:platform-admins` member → Prometheus targets
   page loads on a second request; Alertmanager UI loads on a second request.

3. **Browser, org only:** Prometheus allowed; Alertmanager 403.

4. **Direct :9090 from the Gateway is refused** (the bypass check). From a grafana pod (already
   in `monitoring`, so intra-metrics is not this test) this is the wrong source. From the
   **nginx-gateway data-plane pod**:

   ```bash
   ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n nginx-gateway exec deploy/homelab-gateway-nginx -- \
     wget -qSO- --timeout=5 http://prometheus-stack-kube-prom-prometheus.monitoring.svc.cluster.local:9090/ 2>&1 | head'
   ```

   Expect hang/timeout or connection refused by policy, **not** HTTP 200 of the Prometheus UI.
   The browser path through `prometheus.apps.home.arpa` must still work after login.

5. **Falco still pages:** a falcosidekick test alert still arrives by e-mail
   (`monitoring-alertmanager-falco-ingress` was not changed).

### Rollback

`git revert` the step 3 commit (HTTPRoutes return to prometheus/alertmanager Services, gateway
egress returns to `:9090`/`:9093`, oauth2-proxy Application can be deleted). OpenBao undo is the
`root-run oidc` block in `scripts/openbao-breakglass.sh`.

## Break-glass (ADR 0016 decision 9)

- Grafana local admin: unchanged by this rollout; password in the `grafana-admin` Secret (out of git, ADR 0008).
- Argo CD local admin: stays enabled (`admin.enabled: "true"`); password hash is `argocd-secret` key
  `admin.password` (not `argocd-initial-admin-secret` on this cluster).
- If Gitea is down: SSO logins fail everywhere, the Grafana/Argo CD local admins still log in, and the
  Prometheus/Alertmanager UIs are reachable only through the admin SSH port-forward (ADR 0003) onto
  `:9090`/`:9093` inside the cluster. Argo CD keeps running the cluster; syncs retry.

## 2FA audit (ADR 0016 decision 10)

Gitea 1.27 community can enforce 2FA instance-wide only (`[security] TWO_FACTOR_AUTH=enforced`, no per-org rule).
Until the instance-wide switch is proven safe for token-based CI accounts, check the admin panel per-user 2FA state
for the members of `platform-admins` and record the result here. Current state: checked on ______ by ______.
