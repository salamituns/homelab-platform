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
# Retrying re-reads the newer version, so no update is lost. Any other failure
# (a webhook denial, missing permissions) is reported, not retried: it will not
# heal on its own.
#
# Usage:
#   scripts/k8s-rewrite-secrets.sh             # rewrite all Secrets, print counts
#   scripts/k8s-rewrite-secrets.sh --dry-run   # report flag state + counts, rewrite nothing
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

# The static kube-apiserver pods appear as mirror pods carrying the command the
# running process got. Refuse to rewrite without the flag: the run would report
# success while Secrets keep landing in etcd in plaintext.
apiserver_flag_state() {
  local node state=yes
  for node in $(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}'); do
    if ! kubectl -n kube-system get pod "kube-apiserver-$node" -o jsonpath='{.spec.containers[0].command}' 2>/dev/null \
         | grep -q -- '--encryption-provider-config='; then
      state="no (kube-apiserver-$node is not running with --encryption-provider-config)"
    fi
  done
  echo "$state"
}

FLAG_STATE="$(apiserver_flag_state)"
if $DRY_RUN; then
  echo "API server carries --encryption-provider-config: $FLAG_STATE"
else
  if [[ "$FLAG_STATE" != "yes" ]]; then
    echo "Refusing to rewrite: $FLAG_STATE." >&2
    echo "Run ansible/playbooks/k8s-etcd-encryption.yml first (docs/runbooks/etcd-encryption.md)." >&2
    exit 2
  fi
fi

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
    err=""
    for _ in $(seq 1 "$RETRIES"); do
      # json-to-pipe replace; stderr of both kubectls is captured, stdout data never is
      if err="$( { kubectl -n "$ns" get secret "$secret" -o json | kubectl replace -f - >/dev/null; } 2>&1 )"; then
        ok=true
        break
      fi
      if grep -q '(Conflict)' <<< "$err"; then
        sleep 1   # the Secret changed under us; a retry re-reads the newer version
        continue
      fi
      break   # other errors do not heal by retrying
    done

    if $ok; then
      rewritten=$((rewritten + 1))
    else
      failed=$((failed + 1))
      # Only the HTTP reason word is printed ("Conflict", "Forbidden", ...): it comes
      # from the server status line, so it cannot carry Secret data. The rest of the
      # stderr stays suppressed for the same reason.
      reason="$(sed -n 's/^Error from server (\([A-Za-z ]*\)).*/\1/p' <<< "$err" | head -1)"
      [[ -n "$reason" ]] || reason="error (stderr suppressed; re-run this one by hand to see it)"
      echo "FAILED: $ns/$secret: $reason" >&2
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
  echo "Re-run the script to try the failures again; rewriting an already-encrypted Secret is harmless." >&2
  exit 1
fi
