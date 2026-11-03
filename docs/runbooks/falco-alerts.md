# Falco runtime detection and Alertmanager email alerts

How Falco, `falcosidekick`, and Alertmanager email delivery (ADR 0015 section D, step 5) are configured, verified, and rolled back.

The cluster side is in git:
- `k8s/platform/apps/falco.yaml`, `k8s/platform/falco/values.yaml`, and `k8s/platform/falco/manifests/namespace.yaml` deploy Falco chart `9.2.2` (`modern_ebpf` probe with `leastPrivileged: true`) and `falcosidekick` `2.35.1` forwarding `Notice`+ events to Alertmanager's `/api/v2/alerts` endpoint with `source: falco`.
- `k8s/platform/monitoring/manifests/netpol-allow.yaml` (`monitoring-alertmanager-falco-ingress`) allows `falcosidekick` pods in `falco` to reach Alertmanager `:9093` in `monitoring`, and `monitoring-alertmanager-egress` allows Alertmanager to reach public SMTP servers on `:465`.
- `k8s/platform/monitoring/manifests/{eso-alertmanager-sa.yaml,secretstore-openbao.yaml,externalsecret-alertmanager-config.yaml}` and `k8s/platform/monitoring/values.yaml` (`alertmanager.alertmanagerSpec.configSecret: alertmanager-config-eso`) template the full `alertmanager.yaml` Secret from OpenBao `secret/data/monitoring/alertmanager`.
- `k8s/platform/cluster-config/eso-tokenreview.yaml` grants `system:auth-delegator` to `monitoring/eso-alertmanager` so OpenBao's `TokenReview` succeeds without a long-lived reviewer JWT.

This runbook covers the owner steps, in order.

---

## 1. Create the Gmail App Password (already done)

1. In the Google Account used for homelab alert delivery (2-Step Verification required), open **Security -> 2-Step Verification -> App passwords**.
2. Generate a 16-character App Password named `homelab-alertmanager`.
3. Keep the 16-character password in your offline password manager. Never paste it into a file in the repo or pass it as a CLI flag.

---

## 2. One command: the alert setup through the break-glass root path

OpenBao has no standing root token (ADR 0014), and the manual `bao operator
generate-root` flow this section used to document no longer works: OpenBao 2.7.2 gates
the legacy endpoints the CLI calls (verified 2026-11-03, see `docs/runbooks/openbao.md`
§6). Use the break-glass script instead - one command that prompts for the unseal
shares and the SMTP values (hidden where they should be), mints the root token ON
sectools, runs the setup, and ALWAYS revokes the token at the end (and verifies the
revocation; the token never reaches the Mac or the terminal output):

```bash
# Once, if it has not been run since the flag change (restarts openbao, then unseals):
scripts/openbao-breakglass.sh apply-config

# The alert setup (from scripts/openbao-setup-alertmanager.sh, same API calls):
scripts/openbao-breakglass.sh root-run alertmanager
# Re-running it later is idempotent: it skips the secret if it already exists
# (pass --overwrite to replace the SMTP values).
```

At the prompts: 2 unseal shares (hidden; the store holds 3 shares with a
threshold of 2, verified live 2026-11-03), then the same SMTP fields the setup script
asks for - **SMTP username** (your Gmail address), **From**/**To** addresses (Enter
accepts the username as default), and the **Gmail 16-character App Password** at a
hidden prompt (spaces stripped, never echoed, sent over ssh stdin).

Verify the output reports: the minted token verified as root, the mounts check, the
policy `alertmanager-read` and role `alertmanager` written, `secret/monitoring/alertmanager`
verified with keys `["from","password","to","username"]`, and
"root-run done: command ran, token revoked and verified revoked".

The scripts/openbao-setup-alertmanager.sh stays as the reference for the same calls with
a token you already hold (`--dry-run` still previews the payloads); the break-glass
script embeds identical API calls so the root token never leaves sectools.

The break-glass script arrives with the `week6-bao-breakglass` PR; merge that before (or
with) this PR. Undo of what the alert setup writes is documented in the script header and
in `docs/runbooks/openbao.md`.

---

## 3. Merge the PR and let Argo CD sync

Merge branch `week6-falco` into `main` and push to Gitea (`origin`). Argo CD will:
1. Update `AppProject/platform` (`sourceRepos` adds `https://falcosecurity.github.io/charts`).
2. Update `ClusterRoleBinding/eso-tokenreview-belleshop` (`cluster-config`) with `monitoring/eso-alertmanager`.
3. Sync `monitoring` (`ServiceAccount/eso-alertmanager`, `SecretStore/openbao`, `ExternalSecret/alertmanager-config-eso`, `NetworkPolicy/monitoring-alertmanager-falco-ingress`, and `Alertmanager` `spec.configSecret: alertmanager-config-eso`).
4. Create and sync `Application/falco` in namespace `falco` (3 `falco` DaemonSet pods using `modern_ebpf` + 1 `falco-falcosidekick` Deployment pod).

---

## 4. Verify ESO sync, Alertmanager config, and Falco pods

Using the developer kubeconfig (`olatunde.kubeconfig`):

```bash
export KUBECONFIG="$HOME/homelab-platform/private/k8s-access/olatunde.kubeconfig"

# 1. Verify SecretStore and ExternalSecret in monitoring are Ready=True
kubectl -n monitoring get secretstore openbao
kubectl -n monitoring get externalsecret alertmanager-config-eso

# 2. Verify all 3 Falco DaemonSet pods and 1 falcosidekick pod are Running
kubectl -n falco get pods -o wide

# 3. Confirm Falco loaded the modern_ebpf engine
kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco | grep -i "modern_ebpf"
```

---

## 5. Run `scripts/falco-proof.sh` and verify email delivery

Run the end-to-end proof script:

```bash
./scripts/falco-proof.sh
```

What `scripts/falco-proof.sh` does and verifies:
1. Confirms `ExternalSecret/alertmanager-config-eso` is `Ready=True` and `falco` pods are `Running`.
2. Runs `kubectl -n dev exec -it <backend-pod> -- /bin/sh -c 'id; exit'` with a PTY (`proc.tty != 0`) so Falco's default rule `"Terminal shell in container"` fires.
3. Prints the `"Terminal shell in container"` JSON event from `kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco`.
4. Prints the `AlertManager - Post OK (200)` log entry from `kubectl -n falco logs -l app.kubernetes.io/name=falcosidekick`.
5. Queries Alertmanager (`amtool --alertmanager.url=http://127.0.0.1:9093 alert query -o json source=falco`) and confirms the active alert is routed to `receivers: ["email"]`.

Finally, check the configured `to` inbox (wait `group_wait: 30s`) and confirm the Alertmanager email arrives over `smtp.gmail.com:465` for `[FIRING:1] falco` (`Terminal shell in container` in namespace `dev`). Also check Alertmanager logs for any SMTP errors:

```bash
kubectl -n monitoring logs alertmanager-prometheus-stack-kube-prom-alertmanager-0 -c alertmanager --tail=50
```

---

## 5a. Tuning: exempting a known-good actor

The 24 hours after step 5 went live produced about 60 emails: 64 of 65 Falco events were
the rule `Contact K8S API Server From Container` (Notice) firing for platform
controllers doing their job - `argocd-application-controller-0` (44), the `argo-rollouts`
controller (19), one monitoring admission-create Job. The only other event was the
deliberate shell-in-container proof in `dev`.

What shipped (2026-11-03):

- **Falco side** (`k8s/platform/falco/values.yaml`, `customRules`): the upstream ruleset
  ships `user_known_contact_k8s_api_server_activities` as a `never_true` placeholder
  exactly so a deployment can name its known actors. The override replaces the
  placeholder with `k8s.ns.name in (argocd, argo-rollouts, cert-manager, external-secrets,
  falco, kube-flannel, kube-network-policies, kube-system, kyverno, local-path-storage,
  metallb-system, monitoring, nginx-gateway)` - every namespace that runs platform
  controllers on this cluster, and deliberately **not** `dev` or any app namespace.
  The shell-in-container rule and every other rule are untouched, and an app namespace
  that talks to the API server still pages on first contact.
- **Alertmanager side** (the ESO-templated `alertmanager.yaml`): the `source = "falco"`
  route now has `group_by: [rule, k8s_ns_name]` (the labels falcosidekick really sends;
  it sends no kubernetes `namespace` label) and `repeat_interval: 24h`, so one persistent
  detection is at most one email per rule per namespace per day.
- Validation is real, not assumed: the override plus the live `falco_rules.yaml`
  (extracted from the falco pod, 2026-11-03) passes `falco --validate` in the
  `falcosecurity/falco:0.45.2` image, and a deliberately broken condition in the same
  setup fails with `LOAD_ERR_COMPILE_CONDITION` - so the pass is not vacuous.

To exempt (or stop exempting) another actor:

1. Edit the namespace list in `k8s/platform/falco/values.yaml` (`customRules ->
   homelab-exemptions.yaml`). Prefer adding a **namespace** over a container name: pods
   churn, namespaces are the trust boundary. Never add an app namespace (`dev`) there.
2. Validate exactly as above: pull the live `/etc/falco/falco_rules.yaml` from a falco
   pod, render `customRules` to a file in a `rules.d` directory, and run
   `docker run --rm --entrypoint falco -v ...:/etc/falco/falco_rules.yaml:ro -v ...
   :/etc/falco/rules.d:ro falcosecurity/falco:0.45.2 -V /etc/falco/falco_rules.yaml
   -V /etc/falco/rules.d/homelab-exemptions.yaml` - expect both files `Ok`.
3. Merge; Argo CD syncs the falco app. Re-run `scripts/falco-proof.sh` to confirm the
   shell rule still alerts, and confirm the controller noise is gone from
   `kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco`.

Expected effect (replay of the 24h window above against the shipped exemption): all 64
API-server events come from exempted namespaces, so 0 of them would have reached
Alertmanager; the one real event (the dev shell proof) still emails. Roughly 60
emails/day to about 1/day for the same activity.

---

## 6. Undo

To roll back the cluster and OpenBao changes:

1. **Revert the git commit on `main` and push.** Because `automated.prune: false` is set on Argo CD applications, delete the leftover cluster objects explicitly via the admin SSH path:
   ```bash
   ssh tunsadmin@192.168.1.90 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n argocd delete application falco'
   ssh tunsadmin@192.168.1.90 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf delete namespace falco'
   ssh tunsadmin@192.168.1.90 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n monitoring delete externalsecret alertmanager-config-eso secretstore openbao sa eso-alertmanager secret alertmanager-config-eso netpol monitoring-alertmanager-falco-ingress'
   ```
2. **Remove the OpenBao secret, role, and policy** (using a short-lived root token via `scripts/openbao-breakglass.sh root-run -- curl ...`, which always revokes):
   ```bash
   curl -q -sS --cacert "$BAO_CACERT" -H "X-Vault-Token: $ROOT_TOKEN" \
     -X DELETE "$BAO_ADDR/v1/secret/metadata/monitoring/alertmanager"
   curl -q -sS --cacert "$BAO_CACERT" -H "X-Vault-Token: $ROOT_TOKEN" \
     -X DELETE "$BAO_ADDR/v1/auth/kubernetes/role/alertmanager"
   curl -q -sS --cacert "$BAO_CACERT" -H "X-Vault-Token: $ROOT_TOKEN" \
     -X DELETE "$BAO_ADDR/v1/sys/policies/acl/alertmanager-read"
   BAO_TOKEN="$ROOT_TOKEN" bao token revoke -self
   unset ROOT_TOKEN
   ```
