#!/usr/bin/env bash
# The 15 HTTP checks from ADR 0013: every public hostname x three paths, against one address.
#   scripts/route-smoke.sh 192.168.1.240 > before.txt          # record
#   scripts/route-smoke.sh 192.168.1.240 | diff before.txt -   # compare; exit 1 on any difference
# The status codes are the contract, not 200s: grafana.local / is a 302 to its login page, unknown paths are 404s.
set -euo pipefail

ip="${1:?usage: route-smoke.sh <address>}"
hosts=(argocd.local grafana.local rollouts.local belleshop.local api.belleshop.local)
paths=(/ /api/health /api/products)

for h in "${hosts[@]}"; do
  for p in "${paths[@]}"; do
    code=$(curl -q -s -o /dev/null -m 5 -w '%{http_code}' --resolve "$h:80:$ip" "http://$h$p" || true)
    printf '%-20s %-14s %s\n' "$h" "$p" "$code"
  done
done
