# ADR 0016: OIDC single sign-on for the admin UIs, with Gitea as the provider

- Status: Accepted (owner, 2026-11-03, PR #44). Steps 1–2 in git. Step 3 (oauth2-proxy) prepared against
  chart 10.7.1 / image v7.15.5; owner merges only after the two OpenBao records exist.
- Date: 2026-11-03 (corrections 2026-11-04: Argo CD v3.5.1; oauth2-proxy groups split — Alertmanager
  `homelab:platform-admins` only)

## Context

The Week 6 carry-over list says the admin UIs still authenticate with local accounts: Grafana uses the hand-made
`monitoring/grafana-admin` Secret, Argo CD uses its built-in admin, and the Prometheus and Alertmanager UIs have no
login at all. One identity already exists for every person in the lab: the Gitea account on `192.168.1.97`
(`gitea.home.arpa`, rebuilt per [ADR 0005](0005-gitea-rebuild.md)). The owner decided on 2026-11-03 that **Gitea is
the OIDC provider** — no Dex, Keycloak or Authentik — so the question this ADR answers is how to wire the existing
cluster consumers to it.

This ADR is design only. The rollout belongs to Week 7 and a separate runbook.

Verified on 2026-11-03 (read-only: admin SSH for `kubectl`, curl/openssl from the Mac — the 8h operator certificate
expired, so no pod exec/list with it):

| Area | Current state | Why it matters |
|---|---|---|
| Provider | Gitea 1.27.3 (`sudo gitea --version` over SSH to the Gitea VM). `[oauth2]` in `app.ini` has no `ENABLED` key (default on); JWT keys come from a secret file | Gitea ships a standards-track OIDC provider; nothing to install |
| Discovery | `https://gitea.home.arpa/.well-known/openid-configuration` (fetched with `--cacert`): issuer `https://gitea.home.arpa`; authorize `/login/oauth/authorize`, token `/login/oauth/access_token`, JWKS `/login/oauth/keys`, userinfo `/login/oauth/userinfo`; RS256; PKCE S256 supported; grants `authorization_code` + `refresh_token` | Endpoints and crypto the consumers must be configured with |
| Groups | The discovery doc advertises a `groups` scope and claim. Upstream PR [#17367](https://github.com/go-gitea/gitea/pull/17367): the claim is a list of `"org"` and `"org:team"` strings, **team names lowercased** (`org.Name + ":" + team.LowerName`), in both the ID token (when the `groups` scope is granted) and the userinfo response | Authorization can map Gitea org/team membership to UI roles — no groups means per-user config in every UI |
| TLS | `gitea.home.arpa` is signed by the **Gitea Caddy root** (`ansible/files/ca/gitea-caddy-root.crt`), not the lab root: `openssl verify -CAfile gitea-caddy-root.crt` OK, lab-root fails error 20. Chain: leaf ← "Caddy Local Authority - ECC Intermediate" ← "Caddy Local Authority - 2026 ECC Root" | Every in-cluster consumer must pin the Gitea root. ADR 0015 decision 5 already deferred re-rooting the five Caddy VM roots |
| In-cluster DNS | CoreDNS Corefile forwards `home.arpa:53` to `192.168.1.96` (the gateway). Proven from the grafana pod on 2026-11-03 (read-only admin exec, the one allowed): `gitea.home.arpa` resolves to `192.168.1.97`, and HTTPS `:443` times out (curl error 28) — the monitoring default-deny has no egress rule to `.97` yet, which is exactly the gap decision 11 closes | Pods resolve the provider; the grafana egress rule is required, and the in-pod TLS proof (curl with the mounted Caddy root) belongs to the runbook after the rule merges |
| Argo CD | `argocd-cm` has no `oidc.config` (only resource customizations/exclusions). **`argocd-rbac-cm` is empty**. With no `policy.default` and no matching rule, an SSO user gets no permissions at all (only the built-in local `admin` account carries `role:admin`), so SSO without an RBAC policy fails closed: people can log in but see nothing. The `dex-server` pod runs but is unused. Argo CD's own manifests are out of git ([ADR 0008](0008-argocd-app-of-apps-platform.md)): only Application objects live here | OIDC is a config patch, owner-applied. The RBAC policy must ship in the same change, or SSO logins succeed but are useless |
| Argo CD network | The `argocd-server` egress netpol already allows 443 to `192.168.1.97/32` (plus 5556/5557 to dex); 16 netpols exist in `argocd` | No netpol change needed for Argo CD's OIDC flow (code exchange + JWKS from `argocd-server`) |
| Grafana | kube-prometheus-stack chart 88.3.0 (release `prometheus-stack`), values in `k8s/platform/monitoring/values.yaml`; admin login from the out-of-git `grafana-admin` Secret; served at `grafana.apps.home.arpa` through the shared Gateway (`grafana-httproute.yaml`) | Grafana's `generic_oauth` needs chart values, a CA mount and an egress rule |
| Prometheus / Alertmanager UIs | `prometheus.apps.home.arpa` and `alertmanager.apps.home.arpa` HTTPRoutes point straight at the web ports; ingress is limited to the Gateway data plane (`netpol-allow.yaml`); the Alertmanager UI is unauthenticated and can create silences (`docs/runbooks/monitoring.md`) | Prometheus/Alertmanager have no OIDC support; they need a proxy that does the OIDC dance for them |
| Secret delivery | ESO + OpenBao per [ADR 0014](0014-secrets-and-identity.md); `monitoring` has a namespace-scoped `SecretStore` backed by the sectools Caddy root | Client and cookie secrets follow the proven path, never git |
| Proxy | oauth2-proxy **v7.15.5** (released 2026-10-01; chart 10.7.1, verified on Artifact Hub), image `quay.io/oauth2-proxy/oauth2-proxy:v7.15.5`. v7.15.5 fixes three security advisories, including the credential disclosure in callback error logging and two authentication-bypass issues that require `--trusted-proxy-ip` when running behind a reverse proxy | The only new moving part; pinned like every image in this repo (digest at implementation) |
| Gitea 2FA | Community Gitea can enforce 2FA **instance-wide only**, since 1.24 ([issue #880](https://github.com/go-gitea/gitea/issues/880), closed for 1.24.0): `[security] TWO_FACTOR_AUTH=enforced` in `app.ini`, with a per-auth-source "skip two-factor" option. There is **no per-org or per-team enforcement** (the Enterprise offering advertises that separately), and the upstream author notes the feature has no doc yet | The admin org's 2FA posture is policy + audit, or a global switch with an unverified interaction with token-based CI accounts |

## Scope

In scope: browser single sign-on for **Argo CD, Grafana, the Prometheus UI and the Alertmanager UI**, with Gitea as the
OIDC provider, role mapping from the `groups` claim, secrets via OpenBao/ESO, and the netpol and Gateway changes those
need.

Out of scope (and where it lives instead):

- `kubectl` / API-server OIDC — short-lived client certificates remain ([ADR 0014](0014-secrets-and-identity.md),
  its "Not now" section).
- Gitea, Proxmox, iDRAC and OpenBao logins — each keeps its own auth (their TLS and break-glass are covered by
  [ADR 0015](0015-network-policy-and-platform-hardening.md) and [ADR 0003](0003-break-glass-access.md)).
- Dex, Keycloak, Authentik — rejected below, not revisited.
- Re-rooting the five Caddy VM roots under the lab CA — deferred by ADR 0015 decision 5.
- Prometheus/Alertmanager API access from scripts and in-cluster callers — the netpols for scrape, falcosidekick and
  Argo Rollouts analysis are untouched; only the browser path through the Gateway moves behind oauth2-proxy.

## Options considered

### Identity provider

| Option | For | Against |
|---|---|---|
| **Gitea native OIDC** (chosen) | The identity already exists; one less VM and one less admin UI to run and back up; groups claim available; RS256; PKCE | Smaller feature set than a dedicated IdP (limited claims customisation, no per-org 2FA enforcement); if Gitea is down, every UI login is down (see "Gitea-down behaviour") |
| Dex | Federates many upstream providers; Argo CD integrates with it natively | A second identity component to run for exactly one upstream (Gitea); the running `dex-server` pod is already unused |
| Keycloak / Authentik | Full-featured IdPs | A new VM or namespace, admin UI, backup and certificate each — for a lab with one human and one CI account. The owner's decision of 2026-11-03 rules them out |

### Auth for the Prometheus and Alertmanager UIs

| Option | For | Against |
|---|---|---|
| **oauth2-proxy in front of each host** (chosen) | Neither UI speaks OIDC; oauth2-proxy is a single small deployment per host, understands the OIDC flow including PKCE and the `groups` claim, and keeps the UIs untouched | One more component; cookies; the UIs stay unauthenticated inside the cluster (unchanged from today) |
| Basic-auth at the Gateway (e.g. `SecurityPolicy`) | No new component | A second, parallel credential system; no Gitea group mapping; NGF's BasicAuth support was not verified for this ADR |
| Leave them unauthenticated, rely on netpols | Nothing to do | The Alertmanager UI can silence alerts; the Week 6 carry-over explicitly says to fix it |

## Decisions

1. **Gitea is the single OIDC provider**, and every consumer gets **its own OAuth2 application** in Gitea — four apps
   for three consumers (one per oauth2-proxy host). One app per consumer keeps client secrets and revocation
   independent: a leaked Argo CD secret is revoked without touching Grafana. Redirect URIs, exact because Gitea
   matches them literally:

   | Consumer | Redirect URI |
   |---|---|
   | Argo CD | `https://argocd.apps.home.arpa/auth/callback` |
   | Grafana | `https://grafana.apps.home.arpa/login/generic_oauth` |
   | oauth2-proxy (prometheus) | `https://prometheus.apps.home.arpa/oauth2/callback` |
   | oauth2-proxy (alertmanager) | `https://alertmanager.apps.home.arpa/oauth2/callback` |

2. **Trust the Gitea Caddy root, explicitly, in every consumer**: `ansible/files/ca/gitea-caddy-root.crt` as
   `oidc.config.rootCA` (Argo CD), `tls_client_ca` (Grafana, from a ConfigMap mount) and `--provider-ca-file`
   (oauth2-proxy). ADR 0015 already showed that assuming the lab root covers `gitea.home.arpa` is wrong — the curl
   that worked on the Mac was succeeding through system trust, not the supplied CA. The file is a public
   certificate, so it is shipped as a ConfigMap (`gitea-caddy-root`), not a Secret.

3. **Argo CD: native OIDC, no Dex.** Verified on **v3.5.1** source (`util/settings`, `util/oidc`,
   `util/rbac`, `server/server.go`), not assumed from `stable` docs. Patch `argocd-cm` merge keys only
   (`url`, `admin.enabled`, `oidc.config`) — live `argocd-cm` already has `resource.exclusions` and must
   not be replaced. `data.url` is required: `RedirectURL()` is `url` + `common.CallbackEndpoint` (`/auth/callback`);
   live (2026-11-04) has **no** `url`, so omitting it would send Gitea a localhost/empty redirect (Grafana
   lesson: missing `root_url`). `oidc.config` fields that exist on the v3.5.1 `OIDCConfig` struct: `name`,
   `issuer`, `clientID`, `clientSecret`, `requestedScopes`, `requestedIDTokenClaims`, `rootCA` (PEM string,
   `AppendCertsFromPEM`; not a volume path), `enablePKCEAuthentication` (Gitea advertises S256; confidential
   client still uses PKCE). There is **no** `groups_claim_path`. Secret refs are `$oidc.gitea.clientID` and
   `$oidc.gitea.clientSecret` (`replaceStringSecret`: leading `$`, key without `$` in `argocd-secret`). Dex
   rewrite is skipped when `OIDCConfigRAW` is set; **leave `dex-server` running** until SSO is proven — do
   not delete it in the same change as the OIDC patch.

4. **Argo CD RBAC is group-based and deny-by-default.**
   `argocd-rbac-cm` today is empty, which Argo CD treats as "no permissions" for any user other than the
   built-in `admin` (fail-closed). The rollout keeps `policy.default: ""` explicit (deny), so a later edit cannot
   silently widen it, plus:

   ```text
   g, homelab:platform-admins, role:admin
   g, homelab, role:readonly
   ```

   Members of the org get read-only; the admin team gets admin; anyone else authenticates and can do nothing.

5. **Grafana: `generic_oauth` in the kube-prometheus-stack values**, with the client secret delivered by ESO.
   `grafana.ini.auth.generic_oauth` gets `client_id`, auth/token/userinfo URLs, `scopes`, `tls_client_ca` (the
   ConfigMap mount from decision 2), `groups_attribute_path: groups`, `allowed_groups: ["homelab", "homelab:platform-admins"]`
   (no org membership, no login) and `role_attribute_path`:

   ```text
   contains(groups[*], 'homelab:platform-admins') && 'Admin' || 'Viewer'
   ```

   Recommendation on the open question: org members who are not admins get **Viewer**, not "no access". The lab has
   one human today, so Viewer costs nothing now and avoids a config change when a second member joins. The client
   secret arrives as `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` via `envFromSecret` from an ESO-synced Secret — all
   `grafana.ini` keys have environment equivalents, so the values file stays secret-free. The local admin login
   stays visible as break-glass (Grafana shows both login options with SSO enabled).

6. **Prometheus and Alertmanager: one oauth2-proxy instance per host, both in the `monitoring` namespace** (not a
   new namespace, not one shared instance). Per host: cookies are host-scoped anyway, each instance has its own
   cookie secret and its own Gitea app, and taking one down cannot log out users of the other. In `monitoring`
   because both instances only serve monitoring UIs, the existing `SecretStore` (ADR 0014 path pattern) delivers
   their secrets, and the existing intra-namespace netpol already permits egress from any monitoring pod to
   `:9090`/`:9093`. Pin chart **10.7.1** / image **`v7.15.5`** digest
   `sha256:8498b0d0ef0a7b29686414000a08aee467f02d0299c9ed1e006a8f33fc017916` (quay index, 2026-11-04).
   Behind NGF: `--reverse-proxy`, `--real-client-ip-header=X-Forwarded-For`, `--trusted-proxy-ip=10.244.0.0/16`
   (v7.15.5 `Options.TrustedProxyIPs`; pod-to-pod is not SNATed). Config per instance (v7.15.5 flags only):
   `provider: oidc`, `oidc-issuer-url: https://gitea.home.arpa`, `oidc-groups-claim: groups` (default; there is
   no `groups_claim_path`), `scope: openid profile email groups`, `code-challenge-method: S256`,
   `cookie-secure`, `provider-ca-file` (PEM from ConfigMap **directory** mount of `gitea-caddy-root`),
   exact `redirect-url` `https://<host>/oauth2/callback`. **Groups (2026-11-04 change):** Prometheus
   `--allowed-group homelab`; Alertmanager `--allowed-group homelab:platform-admins` (the UI can create silences).

7. **Authorization mapping, one table for every consumer** (the `groups` claim values are fixed by Gitea:
   org names as-is, team names lowercased — so the configs above must use `homelab:platform-admins`, never
   `Platform-Admins`):

   | Gitea membership | `groups` claim | Argo CD | Grafana | Prometheus UI | Alertmanager UI |
   |---|---|---|---|---|---|
   | org `homelab`, team `platform-admins` | `["homelab", "homelab:platform-admins"]` | `role:admin` | Admin | allowed | allowed |
   | org `homelab` only | `["homelab"]` | `role:readonly` | Viewer | allowed | denied (`--allowed-group`) |
   | no org membership | absent / empty | denied (`policy.default: ""`) | denied (`allowed_groups`) | denied | denied |

8. **Secrets live only in OpenBao**, under the ADR 0014 path pattern: `secret/data/oidc/{argocd,grafana,oauth2-proxy-prometheus,oauth2-proxy-alertmanager}` (client secrets, plus a 32-byte cookie secret per oauth2-proxy instance). In-git consumers (Grafana, the two oauth2-proxy instances) fetch through the existing `monitoring` SecretStore with new ExternalSecrets. Argo CD is out-of-git (ADR 0008), so its client id and secret are written by the owner into the `argocd-secret` keys `oidc.gitea.clientID` and `oidc.gitea.clientSecret` from the OpenBao value over the admin SSH path (value from stdin, never argv). The owner creates the four OAuth2 apps in the Gitea UI and stores each secret in OpenBao with
`scripts/openbao-breakglass.sh root-run oidc <consumer>` — one command; the short-lived root token is minted, used
and revoked on sectools and never reaches the Mac (and cannot: OpenBao's listener is loopback-only and Caddy 403s
the generate-root paths from the network, both verified 2026-11-03).

9. **Break-glass does not change.** The Argo CD built-in admin stays enabled (`argocd-cm`
   `admin.enabled: "true"`; `parseAdminAccount` defaults Enabled true). The password hash is
   `argocd-secret` key `admin.password` (live 2026-11-04 keys: `admin.password`, `admin.passwordMtime`,
   `server.secretkey` — there is no `argocd-initial-admin-secret` in this cluster). Disable local admin
   only after SSO has proven itself (`admin.enabled: "false"`). The Grafana local admin (`grafana-admin`) stays. The oauth2-proxy hosts have no local accounts by
   design; their break-glass is the admin SSH port-forward (read-only path, [ADR 0003](0003-break-glass-access.md)),
   which reaches the web ports without the Gateway and without oauth2-proxy. The in-cluster netpols are the control
   there, and they are unchanged.

10. **2FA: policy and audit now, one global switch later.** Gitea 1.27.3 can enforce 2FA instance-wide only
    (`[security] TWO_FACTOR_AUTH=enforced`, community since 1.24). Because every account on this instance is
    owner-created (registration is disabled), a global switch is the honest recommendation — **after** checking that
    token-based CI access (the Gitea token used by Jenkins and the Argo CD repo credential) is unaffected; the
    upstream feature ships without documentation of its auth-source interactions, so that check is a rollout step,
    not an assumption. Until then: 2FA for members of `platform-admins` is an owner-audited rule (admin panel shows
    per-user 2FA state).

11. **Network changes, each paired** (the fail-open lesson from ADR 0015 section A: an allow is never inert):

    | Change | Namespace | Pairs with |
    |---|---|---|
    | New egress: grafana pods → `192.168.1.97/32:443` (token exchange) | `monitoring` | Existing Argo CD-style rule; Gitea is already reachable from `argocd-server` |
    | New ingress: oauth2-proxy pods `:4180` from the Gateway data plane | `monitoring` | Gateway data-plane egress `:4180` **replaces** `:9090`/`:9093` so the UIs cannot be reached without the proxy |
    | New egress: oauth2-proxy pods → `192.168.1.97/32:443` (code exchange + userinfo) | `monitoring` | Same shape as the grafana rule |
    | Switch: prometheus/alertmanager UI ingress source from "Gateway data plane" to the matching oauth2-proxy instance | `monitoring` | Named oauth2-proxy→upstream egress plus existing `monitoring-intra-metrics` |
    | Grafana UI ingress from the Gateway stays as-is (`:3000`) | `monitoring` | Grafana keeps its own OIDC login, no proxy |
    | Argo CD egress to Gitea | `argocd` | Already present; no change |

    The falcosidekick → alertmanager ingress and the Argo Rollouts → prometheus ingress rules are untouched:
    they name in-cluster callers, not the browser path.

12. **Rollout order: Grafana first, Argo CD second, oauth2-proxy last.** Grafana is in-git and reversible by one
    Argo sync; Argo CD is owner-applied but self-contained; the oauth2-proxy step repoints live HTTPRoutes, so it
    goes last when the OIDC flow is proven twice.

## Gitea-down behaviour

Stated precisely, because it is the main argument against a Gitea-only IdP:

- UI logins fail everywhere (the OIDC redirect cannot start). Grafana and Argo CD still admit their local admin
  accounts (decision 9). The Prometheus and Alertmanager UIs become reachable only through the admin SSH
  port-forward.
- Argo CD **keeps running the cluster** — existing Applications stay deployed, but syncs fail while the repo is
  unreachable; nothing restarts, no workload is touched. (GitOps pulls; it does not need logins.)
- Alerting is unaffected: Prometheus scrapes, alert evaluation, falco events and alertmanager e-mail do not pass
  through Gitea.
- Recovery is automatic once Gitea is back; no consumer needs a restart because each holds its own OIDC state.

## Rollout plan (design; each step reversible)

**Step 0 — shared prep (owner, no cluster change).**

- Create org `homelab` and team `platform-admins` (lowercase, per decision 7), put the owner's account in the team.
- Create the four OAuth2 applications (decision 1) in the Gitea admin UI; store the four client secrets into
  OpenBao paths (decision 8) with `scripts/openbao-breakglass.sh root-run oidc <consumer>` (prompts: 2 unseal
  shares, client id, client secret; cookie secret generated on sectools for oauth2-proxy-*).
- Prove in-cluster reachability: DNS and the netpol gap are proven (context table, grafana pod exec 2026-11-03). The
  remaining proof — TLS verification against the Gitea Caddy root **from a pod** — needs the egress rule from step 1
  first, so it moved into the runbook ([docs/runbooks/oidc-sso.md](../runbooks/oidc-sso.md)), to run right after the
  step 1 merge. If it fails, the rest does not roll out; fix DNS or the CoreDNS forward first.
- Check the 2FA state of every account in the Gitea admin panel (decision 10); record the result in the runbook.

**Step 1 — Grafana (in-git, Argo-synced).** Values change in `k8s/platform/monitoring/values.yaml` (decision 5) plus
the `gitea-caddy-root` ConfigMap, the ESO Secret for the client secret, and the grafana egress netpol (decision 11).
*Proof:* unauthenticated `curl -I https://grafana.apps.home.arpa/login/generic_oauth` answers 302 to Gitea's
authorize endpoint; a browser login via Gitea lands in Grafana with the Admin org role (owner is in
`platform-admins`); the Grafana log shows a token exchange against `192.168.1.97`; the local admin login still
appears on the login page (break-glass). *Rollback:* revert the commit; Argo syncs the old values, the ConfigMap and
the netpol back — the OIDC login button disappears, the local admin never changed.

**Step 2 — Argo CD (owner-applied, out-of-git per ADR 0008).** Back up the live `argocd-cm`, `argocd-rbac-cm` and
`argocd-secret` (`kubectl get -o yaml` to gitignored `~/homelab-platform/private/argocd-backup-<ts>/`) — rollback
is `kubectl replace` of those three files. Apply via `scripts/argocd-oidc-apply.sh` (OpenBao `root-run oidc argocd`
first; merge-patch CMs; secret patch via stdin). Then `kubectl rollout restart deploy/argocd-server`. Live 2026-11-04: the in-process restart rebuilds the login handler (it trusted the Gitea root and redirected fine) but NOT the session manager's HTTP client, built at pod start without rootCA, so every session check failed with `x509: certificate signed by unknown authority` and the browser bounced back to /login. A `kubectl rollout restart deploy/argocd-server` fixed it. RBAC (`policy.csv` / `policy.default` / `scopes`) reloads through the informer without
that restart. *Proof:* `curl -q -sSI https://argocd.apps.home.arpa/auth/login` is 302/303 to Gitea authorize with
`redirect_uri=https://argocd.apps.home.arpa/auth/callback`; browser login via Gitea reaches the Applications list;
the owner (admin team) can sync an app; logs show JWKS against `192.168.1.97`; local admin still works; for the
deny path, a throwaway Gitea account with no org membership authenticates and sees nothing, then is deleted.
*Rollback:* `scripts/argocd-oidc-apply.sh --rollback`.

**Step 3 — oauth2-proxy for the two UIs (in-git, Argo-synced, last).** Owner creates the two Gitea apps and
`root-run oidc oauth2-proxy-prometheus` / `oauth2-proxy-alertmanager` **before** merge (required Secret; the
HTTPRoute moves in the same commit). New Argo app `oauth2-proxy` (chart 10.7.1, two releases, ExternalSecrets
via `openbao-oidc`), HTTPRoutes to those Services, netpol pairs (decision 11) including **removing** Gateway
→ `:9090`/`:9093`. *Proof:* unauthenticated `curl -q -sSI https://prometheus.apps.home.arpa/` is 302 to Gitea
with `redirect_uri=https://prometheus.apps.home.arpa/oauth2/callback`; after login a **second** request with
the session cookie returns the Prometheus UI (a redirect alone is not a login — Argo CD step 2); Alertmanager
the same for `platform-admins` and 403 for org-only; Gateway to prometheus `:9090` is refused; falcosidekick
→ Alertmanager `:9093` still delivers (rule untouched). *Rollback:* revert the commit.

## Consequences

- UI access gains a dependency chain: Gitea, its Caddy TLS, the CoreDNS `home.arpa` forward, and (for
  Prometheus/Alertmanager) oauth2-proxy. Serving the lab does not — GitOps, scraping and alerting never pass
  through Gitea (see "Gitea-down behaviour").
- `argocd-rbac-cm` gains an explicit policy. Today it is empty (fail-closed for any non-`admin` user); the rollout
  writes `policy.default: ""` explicitly and the group mappings, so the intent is recorded rather than implied.
- The `monitoring` namespace gains two small deployments. No netpol widens beyond what decisions 6 and 11 name:
  oauth2-proxy reaches the UIs on ports the intra-metrics rule already allows, and the UI ingress rules get
  *narrower* (oauth2-proxy pods instead of the whole Gateway data plane namespace).
- Argo CD remains out-of-git (ADR 0008), so its OIDC config will be owner-applied and can drift from this document;
  the rollout runbook must paste the applied `argocd-cm`/`argocd-rbac-cm` state after step 2 so the drift is at
  least recorded.
- Team names arrive lowercased in the `groups` claim. Every mapping in this ADR uses `homelab:platform-admins`;
  renaming the Gitea team later silently breaks authorization (users fall back to readonly/Viewer), which is
  exactly the failure mode the single mapping table is meant to make obvious.
- Consumer TLS trust pins the Gitea Caddy root. When ADR 0015 decision 5 is done (re-rooting the VM CAs under the
  lab root), the three consumer configs move with it — they are listed there as follow-ups.
- The Prometheus and Alertmanager UIs remain unauthenticated **inside** the cluster; their protection stays the
  netpol (Gateway data plane / oauth2-proxy pods / falcosidekick only) plus the admin SSH path. oauth2-proxy guards
  the browser path, not the services.
- With only the instance-wide 2FA switch available, `platform-admins` 2FA is an audit rule until the CI-token
  check passes. The check result belongs in the rollout runbook.

## Not now

- **API-server OIDC** (kubectl): short-lived certificates ([ADR 0014](0014-secrets-and-identity.md)) remain the
  teaching tool; the operator certificate renewal path is separate.
- **SSO for Gitea itself, Proxmox, iDRAC, OpenBao**: each keeps local auth; several are UI-only systems with their
  own break-glass (ADR 0003).
- **Instance-wide 2FA enforcement**: pending the CI-token interaction check (decision 10).
- **Bringing Argo CD's own manifests into git**: out-of-git by ADR 0008; revisiting that is its own decision, not a
  side effect of this one.
- **Deleting the `dex-server` deployment**: still intended after SSO is proven (decision 3 originally named it
  as an owner step). It is **not** part of the v3.5.1 OIDC patch: native OIDC already skips Dex when
  `OIDCConfigRAW` is set. Deleting it in the same change as the first login would mix two failure modes.

## References

- Gitea OAuth2 provider: <https://docs.gitea.com/development/oauth2-provider>; groups claim format from upstream
  PR [#17367](https://github.com/go-gitea/gitea/pull/17367); 2FA enforcement history in issue
  [#880](https://github.com/go-gitea/gitea/issues/880) (closed for 1.24.0).
- Argo CD v3.5.1 SSO: <https://argo-cd.readthedocs.io/en/v3.5.1/operator-manual/sso/> (`oidc.config`, "Secrets
  in oidc.config") and RBAC: <https://argo-cd.readthedocs.io/en/v3.5.1/operator-manual/rbac/>. Struct and
  restart behaviour taken from tag `v3.5.1` (`util/settings/settings.go`, `util/oidc/oidc.go`,
  `util/rbac/rbac.go`, `server/server.go`, `common/common.go`), not from `stable`.
- Grafana `generic_oauth`: <https://grafana.com/docs/grafana/latest/setup/configure-security/configure-authentication/generic-oauth/>
  (`allowed_groups`, `role_attribute_path`, `tls_client_ca`).
- oauth2-proxy: <https://oauth2-proxy.github.io/oauth2-proxy/> (OIDC provider, PKCE, `--trusted-proxy-ip`) and
  chart 10.7.1 / app 7.15.5 on Artifact Hub, <https://artifacthub.io/packages/helm/oauth2-proxy/oauth2-proxy>.
- This repo: [ADR 0014](0014-secrets-and-identity.md) (ESO/OpenBao delivery, path pattern),
  [ADR 0015](0015-network-policy-and-platform-hardening.md) (netpol pairing discipline, decision 5 CA deferral),
  [ADR 0008](0008-argocd-app-of-apps-platform.md) (Argo CD out-of-git), [ADR 0013](0013-gateway-api.md) (shared
  Gateway and HTTPRoutes).
