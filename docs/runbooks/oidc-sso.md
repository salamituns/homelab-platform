# Runbook: OIDC SSO for the admin UIs (ADR 0016)

Owner-only. This runbook executes [ADR 0016](../adr/0016-oidc-sso-admin-uis-gitea.md): today it covers the shared
prep (step 0) and Grafana (step 1). Argo CD (step 2) and oauth2-proxy for the Prometheus/Alertmanager UIs (step 3)
are added here when they are implemented. Nothing in this runbook is agent-applied; every command either changes git
via a PR or is run by you.

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

## Break-glass (ADR 0016 decision 9)

- Grafana local admin: unchanged by this rollout; password in the `grafana-admin` Secret (out of git, ADR 0008).
- If Gitea is down: SSO logins fail everywhere, the local admin still logs in, and the Prometheus/Alertmanager UIs
  (no login) are reachable only through the admin SSH port-forward (ADR 0003). Argo CD keeps running the cluster;
  syncs retry.

## 2FA audit (ADR 0016 decision 10)

Gitea 1.27 community can enforce 2FA instance-wide only (`[security] TWO_FACTOR_AUTH=enforced`, no per-org rule).
Until the instance-wide switch is proven safe for token-based CI accounts, check the admin panel per-user 2FA state
for the members of `platform-admins` and record the result here. Current state: checked on ______ by ______.
