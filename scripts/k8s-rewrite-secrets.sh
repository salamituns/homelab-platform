#!/usr/bin/env bash
# Rewrites every Secret in the cluster so the API server stores it encrypted
# (ADR 0014 step 7). Run it AFTER ansible/playbooks/k8s-etcd-encryption.yml:
# enabling encryption alone leaves existing Secrets in plaintext until they are
# written once more.
#
# kubectl get -o json | kubectl replace reads and writes the whole object; the
# data goes pipe-to-pipe and is never printed. Only counts are reported.
#
# Each Secret is retried on conflict: ESO rewrites one Secret on every rotation
# (refreshInterval 1m), so a Secret can change between the get and the replace.
# Retrying re-reads the newer version, so no update is lost.
#
# Usage:
#   scripts/k8s-rewrite-secrets.sh             # rewrite all Secrets, print counts
#   scripts/k8s-rewrite-secrets.sh --dry-run   # list Secrets per namespace, rewrite nothing
#
# Undo: a rewrite writes each object back unchanged, so there is nothing to
# undo here. To stop encrypting at all, see docs/runbooks/etcd-encryption.md:
# identity first, rewrite (that decrypts), then remove the flag.
set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--dry-run]" >&2
  exit 2
fi

RETRIES=5        # per Secret; a conflict resolves in well under a minute
total=0
failed_total=0

for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}'); do
  # -o name so nothing but the Secret names ever leave the cluster.
  # No mapfile: the Mac's bash is older than mapfile. Names are DNS-1125,
  # so word splitting on the loop is safe.
  secrets="$(kubectl -n "$ns" get secrets -o name | sed 's|^secret/||')"
  rewritten=0
  failed=0

  for secret in $secrets; do
    if $DRY_RUN; then
      rewritten=$((rewritten + 1))
      continue
    fi

    ok=false
    for _ in $(seq 1 "$RETRIES"); do
      # json-to-pipe replace: kubectl replace rejects a stale resourceVersion
      # with a 409 conflict, which is exactly the ESO race we retry here
      if kubectl -n "$ns" get secret "$secret" -o json | kubectl replace -f - >/dev/null 2>&1; then
        ok=true
        break
      fi
      sleep 1
    done

    if $ok; then
      rewritten=$((rewritten + 1))
    else
      failed=$((failed + 1))
      echo "FAILED: $ns/$secret (conflict $RETRIES times in a row)" >&2
    fi
  done

  if $DRY_RUN; then
    printf '%-25s %d secret(s) would be rewritten\n' "$ns" "$rewritten"
  else
    printf '%-25s %d rewritten, %d failed\n' "$ns" "$rewritten" "$failed"
  fi
  total=$((total + rewritten))
  failed_total=$((failed_total + failed))
done

if $DRY_RUN; then
  echo "dry run: $total secret(s) would be rewritten"
  exit 0
fi

echo "total: $total rewritten, $failed_total failed"
if [[ $failed_total -gt 0 ]]; then
  echo "Re-run the script: it skips nothing and only retries what changes under it." >&2
  exit 1
fi
