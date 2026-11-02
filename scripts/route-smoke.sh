#!/usr/bin/env bash
# The 20 checks from ADR 0015 step 1: every public hostname x three paths over HTTPS against one
# address, plus one http->https redirect check per hostname. TLS is verified against the vendored
# lab root (ansible/files/ca/lab-root.crt), so this doubles as the cert-manager proof.
#   scripts/route-smoke.sh 192.168.1.240 > before.txt          # record
#   scripts/route-smoke.sh 192.168.1.240 | diff before.txt -   # compare; exit 1 on any difference
# The status codes are the contract, not 200s: grafana / is a 302 to its login page, unknown
# paths are 404s, and http:// is always the 302 redirect (Gateway RequestRedirect, ADR 0015 B).
# The two belleshop hosts answer only after the same rename lands in belleshop-deploy (ADR 0015 B).
set -euo pipefail

ip="${1:?usage: route-smoke.sh <address>}"
ca="$(cd "$(dirname "$0")/.." && pwd)/ansible/files/ca/lab-root.crt"
hosts=(argocd.apps.home.arpa grafana.apps.home.arpa rollouts.apps.home.arpa belleshop.apps.home.arpa api-belleshop.apps.home.arpa)
paths=(/ /api/health /api/products)

for h in "${hosts[@]}"; do
  code=$(curl -q -s -o /dev/null -m 5 -w '%{http_code}' --resolve "$h:80:$ip" "http://$h/" || true)
  printf '%-32s %-14s %s\n' "$h" "http->https" "$code"
  for p in "${paths[@]}"; do
    code=$(curl -q -s -o /dev/null -m 5 -w '%{http_code}' --cacert "$ca" --resolve "$h:443:$ip" "https://$h$p" || true)
    printf '%-32s %-14s %s\n' "$h" "$p" "$code"
  done
done
