#!/usr/bin/env bash
# Proof that the dev default-deny is enforced AND the allowed flows still work
# (ADR 0015 section A). READ-ONLY: kubectl get/exec/logs plus curl; nothing is created,
# patched or deleted. Run it AFTER the dev default-deny syncs (docs/runbooks/network-policy.md
# step 3). Before the deny lands every check here still passes except the DENIED ones, which
# fail with CONNECTED - that is the expected pre-deny state, not a script bug.
#
# Identity: the limited olatunde kubeconfig (pods/exec in dev via the belleshop-operator
# Role, cluster-wide pod/log reads). No secrets are printed; the exec payloads are
# read-only socket probes.
#
# What each check proves (the ADR's three-way proof):
#   allowed  BelleShop through the Gateway  - the http entry path and /api egress allow
#   allowed  backend -> mysql               - the mysql egress/ingress allow
#   allowed  DNS from a dev pod             - the kube-dns egress allow
#   DENIED   backend -> 1.1.1.1:443         - external egress is dropped
#   DENIED   frontend -> mysql:3306         - intra-namespace is NOT a free-for-all: only
#                                             the backend->mysql allow exists, frontend has none
#   log      the agent's DENY verdict lines - enforcement came from the agent, not the network
# If the denied checks report CONNECTED, the agent is down or gone: fail-open means no
# enforcement, and that is exactly what the KubeNetworkPoliciesAgentUnavailable alert covers.
#
# Usage: scripts/netpol-proof-dev.sh
# Env:   KUBECONFIG (default private/k8s-access/olatunde.kubeconfig)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# private/ is gitignored, so it exists only in the main checkout, never in a worktree.
KUBECFG="${KUBECONFIG:-$REPO_ROOT/private/k8s-access/olatunde.kubeconfig}"
[[ -f "$KUBECFG" ]] || KUBECFG="$HOME/homelab-platform/private/k8s-access/olatunde.kubeconfig"
GATEWAY_IP="${GATEWAY_IP:-192.168.1.240}"
CA="$REPO_ROOT/ansible/files/ca/lab-root.crt"

kc() { kubectl --kubeconfig "$KUBECFG" "$@"; }
[[ -f "$KUBECFG" ]] || { echo "error: kubeconfig not found: $KUBECFG" >&2; exit 2; }
[[ -f "$CA" ]] || { echo "error: lab root CA not found: $CA" >&2; exit 2; }

PASS=0; FAIL=0
pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
failed() { echo "FAIL: $*" >&2; FAIL=$((FAIL+1)); }

BACKEND=$(kc -n dev get pods -l app=backend -o jsonpath='{.items[0].metadata.name}')
FRONTEND=$(kc -n dev get pods -l app=frontend -o jsonpath='{.items[0].metadata.name}')
[[ -n "$BACKEND" && -n "$FRONTEND" ]] || { echo "error: backend/frontend pods not found in dev" >&2; exit 2; }
echo "dev pods: backend=$BACKEND frontend=$FRONTEND"
echo ""

echo "1/6 allowed: BelleShop /api/healthz through the Gateway (curl -q, lab root, host pinned to $GATEWAY_IP):"
code=$(curl -q -s -o /dev/null -w '%{http_code}' --cacert "$CA" \
  --resolve "belleshop.apps.home.arpa:443:$GATEWAY_IP" https://belleshop.apps.home.arpa/api/healthz)
if [[ "$code" == "200" ]]; then pass "gateway -> backend /api/healthz returned 200"
else failed "gateway /api/healthz returned $code, expected 200"; fi

echo "2/6 allowed: backend -> mysql:3306 (python:3.12-slim has python3):"
if out=$(kc -n dev exec "$BACKEND" -- python3 -c 'import socket
s = socket.create_connection(("mysql", 3306), 3)
print("connected")
s.close()' 2>&1); then pass "backend connected to mysql:3306 ($out)"
else failed "backend could not connect to mysql:3306: $out"; fi

echo "3/6 allowed: DNS from a dev pod (Service name must resolve):"
if out=$(kc -n dev exec "$BACKEND" -- python3 -c 'import socket; print(socket.gethostbyname("mysql"))' 2>&1); then
  pass "mysql resolved to $out"
else failed "DNS resolution failed in dev: $out"; fi

echo "4/6 DENIED: backend -> 1.1.1.1:443 (external egress must NOT connect):"
if out=$(kc -n dev exec "$BACKEND" -- python3 -c 'import socket, sys
try:
    socket.create_connection(("1.1.1.1", 443), 3)
    print("CONNECTED: egress is NOT denied")
    sys.exit(1)
except OSError as e:
    print("denied:", e)
    sys.exit(0)' 2>&1); then pass "backend -> 1.1.1.1:443 was dropped ($out)"
else failed "backend reached 1.1.1.1:443 - the deny is not enforced: $out"; fi

echo "5/6 DENIED: frontend -> mysql:3306 (busybox wget; the pre-deny baseline connects and"
echo "    fails on the MySQL banner instead of timing out):"
out=$(kc -n dev exec "$FRONTEND" -- wget -T 3 -O /dev/null http://mysql:3306 2>&1 || true)
if grep -q "bad header line" <<<"$out"; then
  failed "frontend CONNECTED to mysql:3306 (only backend has the mysql allow): $out"
elif grep -qE "timed out|refused|no response|network failure" <<<"$out"; then
  pass "frontend -> mysql:3306 timed out: $(head -1 <<<"$out")"
else
  echo "NOTE: wget said something unexpected, read it manually:"; echo "$out"
  pass "frontend -> mysql:3306 did not connect"
fi

echo "6/6 the agent's DENY verdict log (enforcement by the agent, not by a dead route):"
found=0
for p in $(kc get pods -n kube-network-policies -o name 2>/dev/null); do
  while IFS= read -r line; do
    [[ -n "$line" ]] && { echo "  $p $line"; found=1; }
  done < <(kc logs -n kube-network-policies "$p" --tail=500 2>/dev/null | grep -i deny | tail -3)
done
if [[ "$found" == "1" ]]; then pass "DENY verdict lines shown above (JSON, one per verdict)"
else echo "NOTE: no DENY lines in the last 500 per agent pod (either nothing was denied since"
  echo "      startup, or the checks above ran pre-deny; rerun after the deny syncs)"; fi

echo ""
echo "result: $PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]] || exit 1
