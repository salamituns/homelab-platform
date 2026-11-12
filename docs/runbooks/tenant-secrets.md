# Runbook: Tenant secrets in OpenBao and `nexus-pull` via External Secrets Operator

Why and what: [ADR 0014](../adr/0014-secrets-and-identity.md) and [ADR 0019](../adr/0019-internal-developer-platform.md) (D1, D6, Phase 0). Every workload namespace that pulls from `registry.home.arpa` needs a `nexus-pull` Secret (`kubernetes.io/dockerconfigjson` for user `k8s-pull`), and every tenant environment (`<app>-<env>`) needs isolated access to its own OpenBao path (`secret/data/apps/<app>/<env>/*`) plus `secret/data/platform/nexus-pull`.

Previously, `nexus-pull` was copied by hand into `dev`, `kyverno`, and `argo-rollouts` ([`docs/runbooks/argo-rollouts-plugin.md`](argo-rollouts-plugin.md)). This runbook covers:

1. Loading the `k8s-pull` password from `nexus` (`/etc/nexus/secrets/k8s-pull`) into OpenBao KV v2 at `secret/platform/nexus-pull`.
2. Safe owner cut-over of the existing hand-made `nexus-pull` Secrets in `dev`, `kyverno`, and `argo-rollouts` to External Secrets Operator (ESO).
3. Onboarding a tenant `<app>-<env>` with `scripts/openbao-breakglass.sh root-run tenant` and the Kustomize component `k8s/tenants/_kit/secrets/`.

---

## Architecture and least-privilege boundaries

| Namespace(s) | ServiceAccount | SecretStore | OpenBao role | OpenBao policy | Allowed KV v2 read paths |
|---|---|---|---|---|---|
| `dev` (existing) | `eso-nexus-pull` | `openbao-nexus-pull` | `nexus-pull-dev` | `nexus-pull-read` | `secret/data/platform/nexus-pull` |
| `kyverno` (existing) | `eso-nexus-pull` | `openbao-nexus-pull` | `nexus-pull-kyverno` | `nexus-pull-read` | `secret/data/platform/nexus-pull` |
| `argo-rollouts` (existing) | `eso-nexus-pull` | `openbao-nexus-pull` | `nexus-pull-argo-rollouts` | `nexus-pull-read` | `secret/data/platform/nexus-pull` |
| `<app>-<env>` (tenant kit) | `eso` | `openbao` | `tenant-<app>-<env>` | `tenant-<app>-<env>` | `secret/data/apps/<app>/<env>/*`, `secret/data/platform/nexus-pull` |
| `edge-public` | `eso` | `openbao` | `cloudflared` | `cloudflared-read` | `secret/data/platform/cloudflared` |

- **Why `dev` uses `openbao-nexus-pull` / `eso-nexus-pull`:** `belleshop-deploy` already manages `SecretStore/openbao` and `ServiceAccount/eso-belleshop` in `dev` (bound to OpenBao role `belleshop`). Using `openbao-nexus-pull` avoids colliding with `belleshop-deploy` (the same separation used by `monitoring/openbao-oidc` in `k8s/platform/monitoring/manifests/secretstore-openbao-oidc.yaml`).
- **TokenReview delegation (`k8s/platform/cluster-config/eso-tokenreview.yaml`):** OpenBao's Kubernetes auth mount runs with `disable_local_ca_jwt: true` (`scripts/openbao-setup-belleshop.sh`), so OpenBao calls the Kubernetes `TokenReview` API using the client ServiceAccount's own JWT. Every ESO ServiceAccount (`eso-nexus-pull` in `dev`, `kyverno`, `argo-rollouts`, `eso` in `edge-public`, and `eso` in each `<app>-<env>`) must be listed in `ClusterRoleBinding/eso-tokenreview-belleshop`.

---

## Part 1: Owner cut-over for `dev`, `kyverno`, and `argo-rollouts`

Do Step 1 and Step 2 **before** merging/syncing the Git manifests so OpenBao holds `secret/platform/nexus-pull` and the three roles before ESO reconciles the `ExternalSecret`s.

### Step 1. Load `secret/platform/nexus-pull` and create the `nexus-pull-*` roles in OpenBao

There is no standing admin token (the root token was revoked 2026-11-02, [openbao.md](openbao.md) §6).
Admin writes go through `scripts/openbao-breakglass.sh root-run`: it prompts for 2 unseal shares
(hidden), mints a root token ON sectools, runs the step there, then revokes it and verifies the
revocation. The token never reaches the Mac. It runs for real unless you pass `--dry-run`.

```sh
scripts/openbao-breakglass.sh root-run nexus-pull --dry-run   # plan only; prompts for nothing
scripts/openbao-breakglass.sh root-run nexus-pull             # 2 hidden share prompts, then the run
```

Proven 2026-11-07 by `scripts/openbao-breakglass-test.sh` against a throwaway OpenBao (70 passed):
password never printed, re-run skips an existing secret, token revoked and verified revoked.

What the run does:
- Writes ACL policy `nexus-pull-read` (read-only on `secret/data/platform/nexus-pull`).
- Writes Kubernetes auth roles `nexus-pull-dev`, `nexus-pull-kyverno`, and `nexus-pull-argo-rollouts` (bound to `eso-nexus-pull` in each namespace, TTL `1h`).
- Reads `/etc/nexus/secrets/k8s-pull` from `tunsadmin@192.168.1.87` over ssh into a local variable, then sends it to sectools inside the root-run payload over ssh stdin (never argv, never printed) and writes `secret/platform/nexus-pull` (`username`, `password`). Skips writing if it already exists unless `--overwrite` is passed.

### Step 2. Back up the existing hand-made `nexus-pull` Secrets

Save a copy of the live hand-made Secrets on the Mac (`0700` directory under `private/`, gitignored) and record the key set and password length (never print secret values) so you can compare after ESO syncs or roll back immediately:

```sh
umask 077
BK="private/nexus-pull-backup-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BK"

for ns in dev kyverno argo-rollouts; do
  ssh Master "sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n $ns get secret nexus-pull -o json" > "$BK/$ns-nexus-pull.json"
  # Print only metadata and decoded top-level registry key + username (never the password or auth token):
  jq -r '.data[".dockerconfigjson"] | @base64d | fromjson | .auths | to_entries[] | "\(.key): user=\(.value.username) pw_len=\(.value.password | length)"' "$BK/$ns-nexus-pull.json"
done
```

### Step 3. Merge the PR and let Argo CD sync

Merge the branch so Argo CD syncs:
- `cluster-config` (`ClusterRoleBinding/eso-tokenreview-belleshop`, `dev/eso-nexus-pull`, `dev/openbao-nexus-pull`, `dev/nexus-pull` `ExternalSecret`)
- `kyverno` (`kyverno/eso-nexus-pull`, `kyverno/openbao-nexus-pull`, `kyverno/nexus-pull` `ExternalSecret`)
- `argo-rollouts` (`argo-rollouts/eso-nexus-pull`, `argo-rollouts/openbao-nexus-pull`, `argo-rollouts/nexus-pull` `ExternalSecret`)

### Step 4. Cut over the existing hand-made `Secret/nexus-pull` in each namespace

Check the `SecretStore` and `ExternalSecret` status in all three namespaces:

```sh
for ns in argo-rollouts kyverno dev; do
  echo "=== $ns ==="
  ssh Master "sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n $ns get secretstore openbao-nexus-pull -o wide"
  ssh Master "sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n $ns get externalsecret nexus-pull -o wide"
done
```

> **UNVERIFIED behaviour to check on first sync:**
> All `ExternalSecret`s in this repo use `creationPolicy: Owner`. Whether ESO chart `2.14.0` adopts an existing un-owned `Secret` in-place under `creationPolicy: Owner` or reports a `SecretSyncedError` (refusing to overwrite a Secret that has no `ownerReference` to `ExternalSecret/nexus-pull`) is not documented in this repo. Both cases are handled safely below:

- **Case A — ESO adopts the existing Secret in-place (`STATUS=SecretSynced`, `READY=True`):**
  No deletion is needed. Proceed directly to Step 5 to verify `ownerReferences` and the rendered `.dockerconfigjson` fields.

- **Case B — ESO reports `SecretSyncedError` because the hand-made Secret has no `ownerReference`:**
  Delete the hand-made `Secret/nexus-pull` one namespace at a time in lowest-blast-radius order (`argo-rollouts` -> `kyverno` -> `dev`) and immediately force an ESO sync so ESO recreates `Secret/nexus-pull` with `ownerReferences` within seconds:

  1. **`argo-rollouts` first** (only read by kubelet when starting the `copy-gatewayapi-plugin` initContainer on a new controller pod, `imagePullPolicy: IfNotPresent`):
     ```sh
     ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n argo-rollouts delete secret nexus-pull && sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n argo-rollouts annotate externalsecret nexus-pull force-sync="$(date +%s)" --overwrite'
     ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n argo-rollouts wait --for=condition=Ready externalsecret/nexus-pull --timeout=60s'
     ```
  2. **`kyverno` second** (read by Kyverno controllers when verifying `dev` images at admission; run while no `dev` deployment/rollout is in progress):
     ```sh
     ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n kyverno delete secret nexus-pull && sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n kyverno annotate externalsecret nexus-pull force-sync="$(date +%s)" --overwrite'
     ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n kyverno wait --for=condition=Ready externalsecret/nexus-pull --timeout=60s'
     ```
  3. **`dev` third** (read by kubelet only when pulling a new image for a pod in `dev`):
     ```sh
     ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n dev delete secret nexus-pull && sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n dev annotate externalsecret nexus-pull force-sync="$(date +%s)" --overwrite'
     ssh Master 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n dev wait --for=condition=Ready externalsecret/nexus-pull --timeout=60s'
     ```

### Step 5. Verify the ESO-managed `nexus-pull` Secrets and clean up backups

Confirm each `Secret/nexus-pull` is owned by `ExternalSecret/nexus-pull`, carries `type: kubernetes.io/dockerconfigjson` and `argocd.argoproj.io/sync-options: Prune=false`, and renders valid credentials matching the pre-cut-over backup (without printing secret values):

```sh
for ns in argo-rollouts kyverno dev; do
  echo "=== $ns ==="
  ssh Master "sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf -n $ns get secret nexus-pull -o json" \
    | jq -r '{
        type: .type,
        owner: (.metadata.ownerReferences // [] | map("\(.kind)/\(.name)")),
        prune_annotation: .metadata.annotations["argocd.argoproj.io/sync-options"],
        auth_summary: (
          .data[".dockerconfigjson"] | @base64d | fromjson | .auths["registry.home.arpa"]
          | {
              username: .username,
              pw_len: (.password | length),
              auth_matches: (.auth == ("\(.username):\(.password)" | @base64))
            }
        )
      }'
done
```

Expected in all three namespaces:
- `type`: `"kubernetes.io/dockerconfigjson"`
- `owner`: `["ExternalSecret/nexus-pull"]`
- `prune_annotation`: `"Prune=false"`
- `auth_summary`: `username: "k8s-pull"`, `pw_len` matching Step 2, `auth_matches: true`.

Once verified, remove the local backup directory:

```sh
rm -rf "$BK"
```

### Rollback (if ESO sync or template rendering fails during cut-over)

1. Restore the hand-made Secret from `$BK/<ns>-nexus-pull.json` (stripping server metadata):
   ```sh
   for ns in argo-rollouts kyverno dev; do
     jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences)' \
       "$BK/$ns-nexus-pull.json" \
       | ssh Master "sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -"
   done
   ```
2. Revert the Git commit so Argo CD removes the `ExternalSecret`s (`Prune=false` on the Secret prevents Argo CD from deleting `Secret/nexus-pull`).

---

## Part 2: Onboarding a tenant environment (`<app>-<env>`)

### 1. Create the OpenBao policy and Kubernetes auth role

`scripts/openbao-breakglass.sh root-run tenant <app> <env>` validates `<app>` and `<env>` against
`^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` and uses the same break-glass flow (2 hidden shares, token minted
and revoked on sectools, never on the Mac). It runs for real unless you pass `--dry-run`:

```sh
scripts/openbao-breakglass.sh root-run tenant demo staging --dry-run
scripts/openbao-breakglass.sh root-run tenant demo staging
```

Least privilege proven by the harness: a token carrying only `tenant-demo-staging` can read
`secret/apps/demo/staging/*`, and gets 403 on another tenant's path and on platform secrets.

This creates:
- Policy `tenant-<app>-<env>` granting `read` on `secret/data/apps/<app>/<env>/*` and `secret/data/platform/nexus-pull` only.
- Kubernetes auth role `tenant-<app>-<env>` bound to ServiceAccount `eso` in namespace `<app>-<env>` (`token_ttl: 1h`).

### 2. Include `k8s/tenants/_kit/base` in the tenant overlay

In the tenant environment's `kustomization.yaml` (copy `k8s/tenants/_template/<env>/`;
the base kit already pulls `_kit/secrets`), set `namespace: <app>-<env>`, and patch
`SecretStore/openbao`'s role name to `tenant-<app>-<env>`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <app>-<env>
components:
  - ../../_kit/base
patches:
  - target:
      group: external-secrets.io
      version: v1
      kind: SecretStore
      name: openbao
    patch: |-
      - op: replace
        path: /spec/provider/vault/auth/kubernetes/role
        value: tenant-<app>-<env>
```

### 3. Bind `<app>-<env>/eso` in `eso-tokenreview-tenants.yaml`

Add the tenant namespace's `eso` ServiceAccount to
`k8s/platform/tenants/eso-tokenreview-tenants.yaml` (not the BelleShop/platform
binding) so OpenBao can verify its JWT via `TokenReview`. Full kit:
[`tenant-onboarding.md`](tenant-onboarding.md).

```yaml
  - kind: ServiceAccount
    name: eso
    namespace: <app>-<env>
```

### 4. Write the tenant's secret values

Do **not** write tenant values with `root-run -- bao kv put ...`: the values land in argv
and shell history on the Mac and on sectools. For govgraph, `scripts/openbao-breakglass.sh
root-run govgraph-secrets <staging|prod>` prompts hidden for `DATABASE_URL` (plus
`CF_ZONE_ID`/`CF_API_TOKEN` in prod), generates `CRON_SECRET` on sectools, and writes the
child objects argv-free on both sides ([govgraph.md](govgraph.md) step 1). A future tenant
with the same shape should get its own such mode in the script, not a raw `bao kv put`.
