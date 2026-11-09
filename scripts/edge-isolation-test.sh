#!/bin/bash
# Usage (from the Mac, repo root): ssh tunsadmin@192.168.1.90 'bash -s' < scripts/edge-isolation-test.sh
# Phase 1 edge isolation test. Runs ON master (admin kubeconfig). Creates two short-lived
# probe pods that wear the labels of cloudflared and public-gateway-nginx (so the same
# NetworkPolicies select them), one unlabelled probe, runs reachability checks with
# controls, then deletes the probes.
set -uo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
K="sudo -E kubectl"
IMG=public.ecr.aws/docker/library/redis:8.2.3-alpine
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }

probe() { # ns name labels-json
  $K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $2, namespace: $1, labels: $3}
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  # Tolerate the apps pool: the real cloudflared pods repel look-alikes from workernode1/2.
  tolerations: [{key: homelab.arpa/pool, operator: Equal, value: apps, effect: NoSchedule}]
  securityContext: {runAsNonRoot: true, runAsUser: 999, runAsGroup: 999, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: p
      image: $IMG
      command: ["sleep", "900"]
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
EOF
}
cleanup() {
  $K delete pod -n edge-public iso-cf --ignore-not-found --wait=false >/dev/null
  $K delete pod -n nginx-gateway iso-pg --ignore-not-found --wait=false >/dev/null
  $K delete pod -n default iso-plain --ignore-not-found --wait=false >/dev/null
}
trap cleanup EXIT

# Start clean: wait for any probe from an earlier run to be fully gone.
cleanup; $K wait pod -A -l test=edge-isolation --for=delete --timeout=120s >/dev/null 2>&1
probe edge-public   iso-cf    '{app.kubernetes.io/name: cloudflared, test: edge-isolation}'
probe nginx-gateway iso-pg    '{app.kubernetes.io/name: public-gateway-nginx, test: edge-isolation}'
probe default       iso-plain '{test: edge-isolation}'
$K wait pod -n edge-public iso-cf --for=condition=Ready --timeout=90s >/dev/null || { echo "iso-cf not ready"; $K describe pod -n edge-public iso-cf | tail -15; exit 1; }
$K wait pod -n nginx-gateway iso-pg --for=condition=Ready --timeout=90s >/dev/null || { echo "iso-pg not ready"; exit 1; }
$K wait pod -n default iso-plain --for=condition=Ready --timeout=90s >/dev/null || { echo "iso-plain not ready"; exit 1; }

ip() { $K get pod -n "$1" -l "$2" -o jsonpath='{.items[0].status.podIP}'; }
PG=$(ip nginx-gateway app.kubernetes.io/name=public-gateway-nginx,gateway.networking.k8s.io/gateway-name=public-gateway)
HG=$(ip nginx-gateway app.kubernetes.io/name=homelab-gateway-nginx)
CP=$(ip nginx-gateway app.kubernetes.io/name=nginx-gateway)
ARGO=$(ip argocd app.kubernetes.io/name=argocd-server)
GRAF=$(ip monitoring app.kubernetes.io/name=grafana)
DEMO=$($K get pod -n demo-staging -o jsonpath='{.items[0].status.podIP}')
DEMOPORT=$($K get pod -n demo-staging -o jsonpath='{.items[0].spec.containers[0].ports[0].containerPort}')
PGSVC=$($K get svc -n nginx-gateway public-gateway-nginx -o jsonpath='{.spec.clusterIP}')
echo "targets: public-gw=$PG/$PGSVC admin-gw=$HG ctrl=$CP argocd=$ARGO grafana=$GRAF demo=$DEMO:$DEMOPORT"

# reach <ns> <pod> <host> <port>  -> 0 if a TCP connection opens within 4s
reach() { $K exec -n "$1" "$2" -- sh -c "nc -w 4 $3 $4 </dev/null >/dev/null 2>&1"; }
# A missing probe must never count as "blocked" (a vanished pod also fails to connect).
alive() { $K get pod -n "$1" "$2" -o jsonpath='{.status.phase}' 2>/dev/null | grep -qx Running || { bad "probe $1/$2 not running - result void"; return 1; }; }
allow() { alive "$1" "$2" || return; if reach "$1" "$2" "$3" "$4"; then ok "$5 (allowed)"; else bad "$5 should be ALLOWED"; fi; }
deny()  { alive "$1" "$2" || return; if reach "$1" "$2" "$3" "$4"; then bad "$5 should be BLOCKED"; else ok "$5 (blocked)"; fi; }

echo "== cloudflared identity (edge-public)"
allow edge-public iso-cf "$PGSVC" 80  "control: cloudflared -> public-gateway Service :80"
allow edge-public iso-cf 1.1.1.1 443   "control: cloudflared -> internet :443"
if $K exec -n edge-public iso-cf -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then ok "control: cloudflared DNS (allowed)"; else bad "cloudflared DNS should be ALLOWED"; fi
deny  edge-public iso-cf "$HG" 80      "cloudflared -> admin gateway pod :80"
deny  edge-public iso-cf 192.168.1.240 443 "cloudflared -> admin gateway LAN VIP .240:443"
deny  edge-public iso-cf "$ARGO" 8080  "cloudflared -> argocd-server"
deny  edge-public iso-cf "$GRAF" 3000  "cloudflared -> grafana"
deny  edge-public iso-cf 192.168.1.90 6443 "cloudflared -> kube-apiserver (LAN)"
deny  edge-public iso-cf 192.168.1.95 443  "cloudflared -> OpenBao (LAN)"
deny  edge-public iso-cf 192.168.1.1 443   "cloudflared -> router (LAN)"
deny  edge-public iso-cf 1.1.1.1 22        "cloudflared -> internet on a non-tunnel port"

echo "== public-gateway identity (nginx-gateway)"
allow nginx-gateway iso-pg "$CP" 8443  "control: public-gateway -> NGF control plane :8443"
deny  nginx-gateway iso-pg "$ARGO" 8080 "public-gateway -> argocd-server"
deny  nginx-gateway iso-pg "$GRAF" 3000 "public-gateway -> grafana"
deny  nginx-gateway iso-pg "$DEMO" "$DEMOPORT" "public-gateway -> internal tenant (demo-staging)"
deny  nginx-gateway iso-pg 192.168.1.95 443 "public-gateway -> OpenBao (LAN)"
deny  nginx-gateway iso-pg 1.1.1.1 443  "public-gateway -> internet"

echo "== who may reach the public gateway"
allow edge-public iso-cf "$PG" 80      "control: cloudflared -> public-gateway pod :80"
deny  default iso-plain "$PG" 80        "unlabelled pod (default ns) -> public-gateway pod"
allow default iso-plain "$HG" 80        "control: unlabelled pod -> admin gateway (in-cluster allowed)"
if timeout 5 bash -c "</dev/tcp/$PG/80" 2>/dev/null; then bad "master host (LAN) -> public-gateway pod should be BLOCKED"; else ok "master host (LAN) -> public-gateway pod (blocked)"; fi
if $K get svc -n nginx-gateway public-gateway-nginx -o jsonpath='{.spec.type} {.status.loadBalancer.ingress}' | grep -qx "ClusterIP "; then ok "public-gateway Service is ClusterIP with no LAN address"; else bad "public-gateway Service exposes a LAN address"; fi

echo "TOTAL pass=$pass fail=$fail"
