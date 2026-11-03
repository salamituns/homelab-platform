#!/usr/bin/env bash
# End-to-end runtime detection proof for ADR 0015 section D (step 5):
#   1. Verify Falco (modern_ebpf) and falcosidekick pods are Running in namespace `falco`,
#      and ExternalSecret `monitoring/alertmanager-config-eso` is Ready=True.
#   2. Spawn an interactive shell (`kubectl -n dev exec -it <backend-pod> -- /bin/sh -c 'id; exit'`)
#      using the developer kubeconfig (`olatunde.kubeconfig`, which has `pods/exec` in `dev`
#      and `pods`, `pods/log` cluster-wide). A PTY is required so `proc.tty != 0` matches
#      Falco's default rule `"Terminal shell in container"`.
#   3. Show the `"Terminal shell in container"` event in `falco` pod logs (`kubectl -n falco logs`).
#   4. Show `falcosidekick` forwarding the event to Alertmanager (`AlertManager - Post OK (200)`).
#   5. Query Alertmanager (`/api/v2/alerts` via `amtool`) and show the active `source="falco"`
#      alert routed to receiver `email`.

set -euo pipefail

DRY_RUN=false
KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/homelab-platform/private/k8s-access/olatunde.kubeconfig}"
MASTER_SSH="${MASTER_SSH:-tunsadmin@192.168.1.90}"

usage() {
  cat <<'EOF'
Usage: falco-proof.sh [--dry-run]

Options:
  --dry-run   Print the proof steps without contacting the cluster.
  -h, --help  Show this help text.

Environment:
  KUBECONFIG  Path to developer kubeconfig (default: ~/homelab-platform/private/k8s-access/olatunde.kubeconfig)
  MASTER_SSH  SSH target for read-only Alertmanager amtool query fallback (default: tunsadmin@192.168.1.90)
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$DRY_RUN" == "true" ]]; then
  cat <<EOF
[dry-run] KUBECONFIG=${KUBECONFIG_PATH}
[dry-run] 1. Check Falco + falcosidekick pods in namespace 'falco' and ExternalSecret 'monitoring/alertmanager-config-eso'
[dry-run] 2. Run: kubectl --kubeconfig="${KUBECONFIG_PATH}" -n dev exec -it <backend-pod> -- /bin/sh -c 'id; exit'
[dry-run] 3. Inspect Falco logs: kubectl --kubeconfig="${KUBECONFIG_PATH}" -n falco logs -l app.kubernetes.io/name=falco -c falco --since-time=<ts>
[dry-run] 4. Inspect falcosidekick logs: kubectl --kubeconfig="${KUBECONFIG_PATH}" -n falco logs -l app.kubernetes.io/name=falcosidekick --since-time=<ts>
[dry-run] 5. Query Alertmanager: amtool --alertmanager.url=http://127.0.0.1:9093 alert query -o json source=falco
EOF
  exit 0
fi

for cmd in kubectl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found in PATH" >&2
    exit 1
  fi
done

if [[ ! -r "$KUBECONFIG_PATH" ]]; then
  echo "ERROR: KUBECONFIG is not readable: $KUBECONFIG_PATH" >&2
  exit 1
fi

kc() {
  kubectl --kubeconfig="$KUBECONFIG_PATH" "$@"
}

echo "==> [1/5] Checking Falco pods in 'falco' and ESO sync in 'monitoring'"
kc -n falco get pods -o wide
es_ready="$(kc -n monitoring get externalsecret alertmanager-config-eso -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
if [[ "$es_ready" != "True" ]]; then
  echo "ERROR: ExternalSecret monitoring/alertmanager-config-eso is not Ready (status=${es_ready:-unknown})" >&2
  exit 1
fi
echo "    OK: ExternalSecret monitoring/alertmanager-config-eso Ready=True"

DEV_POD="$(kc -n dev get pods -l app=backend --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
DEV_NODE="$(kc -n dev get pod "$DEV_POD" -o jsonpath='{.spec.nodeName}')"
if [[ -z "$DEV_POD" ]]; then
  echo "ERROR: no Running app=backend pod found in namespace dev" >&2
  exit 1
fi

SINCE_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "==> [2/5] Spawning interactive shell (TTY) in dev/${DEV_POD} (node ${DEV_NODE}) at ${SINCE_TIME}"
if [[ -t 0 ]]; then
  kc -n dev exec -it "$DEV_POD" -- /bin/sh -c 'id; exit'
else
  # Allocate a local pseudo-terminal when invoked from a non-interactive shell so `kubectl exec -it`
  # sets `proc.tty != 0` inside the container and triggers "Terminal shell in container".
  if [[ "$(uname -s)" == "Darwin" ]]; then
    script -q /dev/null kubectl --kubeconfig="$KUBECONFIG_PATH" -n dev exec -it "$DEV_POD" -- /bin/sh -c 'id; exit' </dev/null
  else
    script -q -c "kubectl --kubeconfig=\"$KUBECONFIG_PATH\" -n dev exec -it \"$DEV_POD\" -- /bin/sh -c 'id; exit'" /dev/null </dev/null
  fi
fi

echo "==> [3/5] Waiting for 'Terminal shell in container' in Falco DaemonSet logs (since ${SINCE_TIME})"
falco_match=""
for _ in {1..15}; do
  falco_logs="$(kc -n falco logs -l app.kubernetes.io/name=falco -c falco --since-time="$SINCE_TIME" --prefix=true 2>/dev/null || true)"
  if grep -q "Terminal shell in container" <<<"$falco_logs"; then
    falco_match="$(grep "Terminal shell in container" <<<"$falco_logs" | tail -n 1)"
    break
  fi
  sleep 1
done

if [[ -z "$falco_match" ]]; then
  echo "ERROR: 'Terminal shell in container' event not found in Falco logs within 15s" >&2
  exit 1
fi
echo "    OK: Falco detected event:"
echo "    ${falco_match}"

echo "==> [4/5] Checking falcosidekick forward to Alertmanager"
sidekick_match=""
for _ in {1..15}; do
  sidekick_logs="$(kc -n falco logs -l app.kubernetes.io/name=falcosidekick --since-time="$SINCE_TIME" 2>/dev/null || true)"
  if grep -qiE "AlertManager - Post OK|alertmanager.*200" <<<"$sidekick_logs"; then
    sidekick_match="$(grep -iE "AlertManager|Terminal shell in container" <<<"$sidekick_logs" | tail -n 5)"
    break
  fi
  sleep 1
done

if [[ -z "$sidekick_match" ]]; then
  echo "ERROR: falcosidekick Alertmanager POST confirmation not found in logs within 15s" >&2
  exit 1
fi
echo "    OK: falcosidekick forwarded event to Alertmanager:"
while IFS= read -r line; do
  echo "    ${line}"
done <<<"$sidekick_match"

echo "==> [5/5] Querying Alertmanager API (/api/v2/alerts via amtool) for source=falco"
query_amtool() {
  if kc -n monitoring auth can-i create pods/exec >/dev/null 2>&1; then
    kc -n monitoring exec alertmanager-prometheus-stack-kube-prom-alertmanager-0 -c alertmanager -- \
      amtool --alertmanager.url=http://127.0.0.1:9093 alert query -o json source=falco
  else
    ssh "$MASTER_SSH" \
      'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n monitoring exec alertmanager-prometheus-stack-kube-prom-alertmanager-0 -c alertmanager -- amtool --alertmanager.url=http://127.0.0.1:9093 alert query -o json source=falco'
  fi
}

am_json=""
for _ in {1..10}; do
  am_json="$(query_amtool)"
  if [[ "$(jq 'length' <<<"$am_json")" -gt 0 ]]; then
    break
  fi
  sleep 1
done

if [[ "$(jq 'length' <<<"$am_json")" -eq 0 ]]; then
  echo "ERROR: no active source=falco alert found in Alertmanager" >&2
  exit 1
fi

echo "    OK: active Falco alert(s) in Alertmanager:"
jq '[.[] | {
  alertname: .labels.alertname,
  rule: .labels.rule,
  priority: .labels.priority,
  source: .labels.source,
  namespace: (.labels.k8s_ns_name // .labels."k8s.ns.name"),
  pod: (.labels.k8s_pod_name // .labels."k8s.pod.name"),
  receivers: [.receivers[].name],
  state: .status.state,
  startsAt: .startsAt
}]' <<<"$am_json"
echo "==> PASS: Falco -> falcosidekick -> Alertmanager pipeline verified end-to-end."
