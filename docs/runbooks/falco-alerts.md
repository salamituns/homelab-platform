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

## 2. Mint a short-lived OpenBao root token (owner terminal only)

OpenBao has no standing root token (ADR 0014). Mint one in your own Mac terminal (never via `!` inside an agent session) using 3 of 5 unseal keys (`docs/runbooks/openbao.md`):

```bash
export BAO_ADDR="https://bao.home.arpa"
export BAO_CACERT="$HOME/homelab-platform/ansible/files/ca/sectools-caddy-root.crt"

OTP="$(bao operator generate-root -generate-otp)"
NONCE="$(bao operator generate-root -init -otp="$OTP" -format=json | jq -r .nonce)"

# Run 3 times, pasting one distinct unseal key at each hidden prompt:
bao operator generate-root -nonce="$NONCE"
bao operator generate-root -nonce="$NONCE"
ENCODED="$(bao operator generate-root -nonce="$NONCE" -format=json | jq -r .encoded_root_token)"

ROOT_TOKEN="$(bao operator generate-root -decode="$ENCODED" -otp="$OTP")"
```

---

## 3. Run `scripts/openbao-setup-alertmanager.sh`

Preview the planned API calls first (no network calls or token required):

```bash
./scripts/openbao-setup-alertmanager.sh --dry-run
```

Then run the setup script against `https://bao.home.arpa`:

```bash
BAO_ADDR="https://bao.home.arpa" \
BAO_CACERT="$HOME/homelab-platform/ansible/files/ca/sectools-caddy-root.crt" \
BAO_TOKEN="$ROOT_TOKEN" \
  ./scripts/openbao-setup-alertmanager.sh
```

At the interactive prompts:
- **SMTP username**: enter your Gmail address.
- **Alert From address**: press Enter to accept the default (`username`), or enter your sender address.
- **Alert To address**: press Enter to accept the default (`username`), or enter your recipient address.
- **Gmail 16-character App Password**: paste the App Password at the hidden `read -rs` prompt (spaces are stripped automatically; the value is never echoed and is piped via stdin to OpenBao).

Verify the output reports:
- Policy `alertmanager-read` written (`HTTP 204`)
- Role `alertmanager` verified (`SA=monitoring/eso-alertmanager, policies=[alertmanager-read], ttl=3600s`)
- Keys `["from","password","to","username"]` verified at `secret/monitoring/alertmanager`

---

## 4. Revoke the root token immediately

Before merging or doing anything else, revoke the temporary root token and clear shell variables:

```bash
BAO_TOKEN="$ROOT_TOKEN" bao token revoke -self
unset ROOT_TOKEN OTP NONCE ENCODED
```

---

## 5. Merge the PR and let Argo CD sync

Merge branch `week6-falco` into `main` and push to Gitea (`origin`). Argo CD will:
1. Update `AppProject/platform` (`sourceRepos` adds `https://falcosecurity.github.io/charts`).
2. Update `ClusterRoleBinding/eso-tokenreview-belleshop` (`cluster-config`) with `monitoring/eso-alertmanager`.
3. Sync `monitoring` (`ServiceAccount/eso-alertmanager`, `SecretStore/openbao`, `ExternalSecret/alertmanager-config-eso`, `NetworkPolicy/monitoring-alertmanager-falco-ingress`, and `Alertmanager` `spec.configSecret: alertmanager-config-eso`).
4. Create and sync `Application/falco` in namespace `falco` (3 `falco` DaemonSet pods using `modern_ebpf` + 1 `falco-falcosidekick` Deployment pod).

---

## 6. Verify ESO sync, Alertmanager config, and Falco pods

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

## 7. Run `scripts/falco-proof.sh` and verify email delivery

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

## 8. Undo

To roll back the cluster and OpenBao changes:

1. **Revert the git commit on `main` and push.** Because `automated.prune: false` is set on Argo CD applications, delete the leftover cluster objects explicitly via the admin SSH path:
   ```bash
   ssh tunsadmin@192.168.1.90 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n argocd delete application falco'
   ssh tunsadmin@192.168.1.90 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf delete namespace falco'
   ssh tunsadmin@192.168.1.90 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n monitoring delete externalsecret alertmanager-config-eso secretstore openbao sa eso-alertmanager secret alertmanager-config-eso netpol monitoring-alertmanager-falco-ingress'
   ```
2. **Remove the OpenBao secret, role, and policy** (using a short-lived root token minted as in step 2, then revoked):
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
