#!/usr/bin/env bash
# Parameterized network-policy proof (ADR 0015 section A, round 2 and later). READ-ONLY:
# kubectl get/exec/logs plus curl; nothing is created, patched or deleted.
#
# Usage: scripts/netpol-proof.sh <dev|nginx-gateway|monitoring|argo-rollouts|argocd>
# Run AFTER that namespace's allow+deny PR syncs (docs/runbooks/network-policy.md).
# This file is deliberately identical on every round-2 branch so the sequential merges
# never conflict; a case simply checks whatever is live when it is invoked.
#
# Why the denied checks run FROM a dev pod: the limited kubeconfig can exec only in dev
# (the belleshop-operator Role is dev-scoped, verified 2026-11-02), and the gateway,
# prometheus and argocd images have no usable shell anyway. A python3 socket probe from
# a dev backend pod exercises the real path: dev egress rule + the target namespace's
# ingress rules, post-DNAT, exactly as the agent evaluates it.
#
# No secrets are printed. Every curl uses -q and the vendored lab root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# private/ is gitignored, so it exists only in the main checkout, never in a worktree.
KUBECFG="${KUBECONFIG:-$REPO_ROOT/private/k8s-access/olatunde.kubeconfig}"
[[ -f "$KUBECFG" ]] || KUBECFG="$HOME/homelab-platform/private/k8s-access/olatunde.kubeconfig"
GATEWAY_IP="${GATEWAY_IP:-192.168.1.240}"
CA="$REPO_ROOT/ansible/files/ca/lab-root.crt"
NS="${1:-}"

kc() { kubectl --kubeconfig "$KUBECFG" "$@"; }
PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
failed() { echo "FAIL: $*" >&2; FAIL=$((FAIL+1)); }

[[ -f "$KUBECFG" ]] || { echo "error: kubeconfig not found: $KUBECFG" >&2; exit 2; }
[[ -f "$CA" ]] || { echo "error: lab root CA not found: $CA" >&2; exit 2; }
case "$NS" in
  dev|nginx-gateway|monitoring|argo-rollouts|argocd) ;;
  *) echo "usage: $0 <dev|nginx-gateway|monitoring|argo-rollouts|argocd>" >&2; exit 2 ;;
esac

# ---- shared checks -----------------------------------------------------------

# Allowed: one https host through the Gateway (curl -q, lab root, host pinned to .240).
allowed_route() {   # $1 label  $2 host  [$3 path]
  local label="$1" host="$2" path="${3:-/}"
  local code
  code=$(curl -q -s -o /dev/null -w '%{http_code}' --cacert "$CA" \
    --resolve "$host:443:$GATEWAY_IP" "https://$host$path")
  if [[ "$code" =~ ^2|^3 ]]; then pass "$label: https://$host$path -> $code"
  else failed "$label: https://$host$path -> $code (expected 2xx/3xx)"; fi
}

# Socket probe from a dev backend pod. $1 expect allow|deny  $2 host-or-IP  $3 port
dev_probe() {
  local expect="$1" target="$2" port="$3" out backend
  backend=$(kc -n dev get pods -l app=backend -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$backend" ]] || { echo "error: no backend pod in dev" >&2; exit 2; }
  out=$(kc -n dev exec "$backend" -- python3 -c 'import socket, sys
target, port = sys.argv[1], int(sys.argv[2])
try:
    socket.create_connection((target, port), 3)
    print("CONNECTED")
except OSError as e:
    print("DENIED:", e)' "$target" "$port" 2>&1)
  if [[ "$expect" == "allow" && "$out" == CONNECTED ]]; then
    pass "dev backend -> $target:$port connected"
  elif [[ "$expect" == "deny" && "$out" == DENIED:* ]]; then
    pass "dev backend -> $target:$port denied ($out)"
  else
    failed "dev backend -> $target:$port expected $expect, got: $out"
  fi
}

# The agent's DENY verdict lines (enforcement evidence; see the runbook for the #417
# probe-tail noise: DENY alone with passing probes is not a failure).
denverdicts() {   # $1 grep pattern (namespace or object name)
  local p found=0
  for p in $(kc get pods -n kube-network-policies -o name 2>/dev/null); do
    while IFS= read -r line; do
      [[ -n "$line" ]] && { echo "  $p $line"; found=1; }
    # grep exits 1 on no match; with pipefail that aborted the whole script after
    # the last matching agent pod (nginx-gateway/monitoring/argocd modes, 2026-11-03).
    done < <(kc logs -n kube-network-policies "$p" --tail=500 2>/dev/null | grep -i deny | grep -i "$1" | tail -3 || true)
  done
  if [[ "$found" == "0" ]]; then
    echo "  (no DENY verdict lines matching '$1' in the last 500 per agent pod)"
  fi
}

# Argo CD application sync+health (readable with the limited cert; a Synced/Healthy app
# is end-to-end evidence for the controller, repo-server, redis and git fetch paths).
app_state() {   # $1 app name  $2 label
  local app="$1" label="$2" sync health
  sync=$(kc -n argocd get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null)
  health=$(kc -n argocd get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null)
  if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
    pass "$label: Argo CD app $app Synced/Healthy"
  else
    failed "$label: Argo CD app $app sync=$sync health=$health (controller/repo-server/redis or git fetch is broken)"
  fi
}

# ---- per-namespace checks ----------------------------------------------------

if [[ "$NS" == "dev" ]]; then
  exec "$REPO_ROOT/scripts/netpol-proof-dev.sh"
fi

if [[ "$NS" == "nginx-gateway" ]]; then
  echo "== nginx-gateway: every route through the Gateway (data-plane ingress + backend egress) =="
  allowed_route "argocd route"    argocd.apps.home.arpa
  allowed_route "grafana route"   grafana.apps.home.arpa
  allowed_route "rollouts route"  rollouts.apps.home.arpa
  allowed_route "belleshop route" belleshop.apps.home.arpa /api/healthz

  echo "== control plane watches the API (it writes the Gateway status) =="
  prog=$(kc -n nginx-gateway get gateway homelab-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
  if [[ "$prog" == "True" ]]; then pass "Gateway homelab-gateway Programmed=True (control plane -> API works)"
  else failed "Gateway Programmed=$prog (control plane cannot reach or program the API)"; fi

  echo "== denied: data-plane metrics port from a pod (ingress allows only 80/443) =="
  dp=$(kc -n nginx-gateway get pods -l app.kubernetes.io/name=homelab-gateway-nginx -o jsonpath='{.items[0].status.podIP}')
  [[ -n "$dp" ]] && dev_probe deny "$dp" 9113

  echo "== agent DENY verdicts mentioning nginx-gateway =="
  denverdicts nginx-gateway
fi

if [[ "$NS" == "monitoring" ]]; then
  echo "== monitoring: grafana through the Gateway (ingress from nginx-gateway only) =="
  allowed_route "grafana route" grafana.apps.home.arpa

  echo "== monitoring: the stack is up and the app that owns it is healthy =="
  app_state monitoring "monitoring app"
  ready=$(kc -n monitoring get pods -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [[ "$ready" == "True" ]]; then pass "prometheus pod Ready (scrape engine up; TargetDown in Grafana is the post-merge watch)"
  else failed "prometheus pod not Ready"; fi

  echo "== denied: grafana from a dev pod (its ingress allows only nginx-gateway and monitoring) =="
  dev_probe deny prometheus-stack-grafana.monitoring.svc.cluster.local 80

  echo "== agent DENY verdicts mentioning monitoring =="
  denverdicts monitoring
fi

if [[ "$NS" == "argo-rollouts" ]]; then
  echo "== argo-rollouts: dashboard through the Gateway (ingress from nginx-gateway only) =="
  allowed_route "rollouts dashboard route" rollouts.apps.home.arpa

  echo "== argo-rollouts: controller healthy and the app synced =="
  app_state argo-rollouts "argo-rollouts app"
  ready=$(kc -n argo-rollouts get pods -l app.kubernetes.io/name=argo-rollouts -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [[ "$ready" == "True" ]]; then pass "argo-rollouts controller Ready (Prometheus analysis is the post-merge canary watch)"
  else failed "argo-rollouts controller not Ready"; fi

  echo "== denied: dashboard from a dev pod (its ingress allows only nginx-gateway) =="
  dev_probe deny argo-rollouts-dashboard.argo-rollouts.svc.cluster.local 3100

  echo "== agent DENY verdicts mentioning argo-rollouts =="
  denverdicts argo-rollouts
fi

if [[ "$NS" == "argocd" ]]; then
  echo "== argocd: the UI through the Gateway =="
  allowed_route "argocd route" argocd.apps.home.arpa

  echo "== argocd: every app Synced/Healthy (controller + repo-server + redis + gitea fetch) =="
  total=0; bad=0
  while IFS=$'\t' read -r app sync health; do
    total=$((total+1))
    if [[ "$sync" != "Synced" || "$health" != "Healthy" ]]; then
      failed "Argo CD app $app sync=$sync health=$health"
      bad=$((bad+1))
    fi
  # jsonpath with tabs: custom-columns pads with spaces, so IFS=tab left
  # sync/health empty and every Synced/Healthy app was reported FAIL (2026-11-03).
  done < <(kc -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}' 2>/dev/null)
  if [[ "$bad" == "0" && "$total" -gt 0 ]]; then
    pass "all $total Argo CD applications Synced/Healthy (repo-server fetched gitea, controller watched the API, redis answered)"
  fi

  echo "== denied: redis from a dev pod (upstream policy allows only the three controllers) =="
  dev_probe deny argocd-redis.argocd.svc.cluster.local 6379
  echo "== denied: repo-server from a dev pod (upstream policy allows only argocd components) =="
  dev_probe deny argocd-repo-server.argocd.svc.cluster.local 8081

  echo "== agent DENY verdicts mentioning argocd =="
  denverdicts argocd
fi

echo ""
echo "result: $PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]] || exit 1
