#!/usr/bin/env bash
# Load the lab CA intermediate into the cluster as the Secret the lab-ca ClusterIssuer reads
# (ADR 0015 section B). OWNER runs this on the Mac: the intermediate certificate and key are
# piped to the admin kubeconfig on the control-plane node over SSH, as stdin, never on a
# command line and never printed. The key exists only in private/ca/ (gitignored) and in the
# cluster Secret, which is encrypted at rest (ADR 0014 step 8).
#
# Usage:
#   scripts/ca-load-intermediate.sh --dry-run    # show the Secret metadata and the ssh command, no send
#   scripts/ca-load-intermediate.sh
#
# Env:
#   CA_DIR       default private/ca
#   CA_SSH_HOST  default Master (the ansible inventory name for the control-plane node;
#                same convention as K8S_ACCESS_SSH_HOST in scripts/k8s-issue-access-cert.sh)
#   OPENSSL_BIN  default openssl (used only for public facts and chain verification)
#
# Idempotence: kubectl apply of the same content changes nothing; re-running after rotating the
# intermediate (same script after ca-create-root.sh produced a new one) updates the Secret and
# cert-manager reissues every leaf from it.
#
# Undo:
#   ssh Master 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n cert-manager delete secret lab-ca-intermediate'
#   (the ClusterIssuer goes NotReady and issuance stops; existing leafs keep serving until expiry)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CA_DIR="${CA_DIR:-$REPO_ROOT/private/ca}"
SSH_HOST="${CA_SSH_HOST:-Master}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
[[ $# -gt 0 && "$1" != "--dry-run" ]] && { echo "usage: $0 [--dry-run]" >&2; exit 2; }

INT_CRT="$CA_DIR/lab-intermediate.crt"; INT_KEY="$CA_DIR/lab-intermediate.key"
ROOT_CRT="$CA_DIR/lab-root.crt"
SECRET_NAME="lab-ca-intermediate"; SECRET_NS="cert-manager"

for f in "$ROOT_CRT" "$INT_CRT" "$INT_KEY"; do
  [[ -e "$f" ]] || { echo "error: $f not found; run scripts/ca-create-root.sh first" >&2; exit 1; }
done

# Prove this intermediate belongs to the lab root before sending it anywhere.
"$OPENSSL_BIN" verify -CAfile "$ROOT_CRT" "$INT_CRT" >/dev/null \
  || { echo "error: $INT_CRT does not verify against $ROOT_CRT" >&2; exit 1; }

# Public facts about what is being loaded; the key is never printed.
echo "Loading intermediate for the lab-ca ClusterIssuer (ADR 0015 B):"
"$OPENSSL_BIN" x509 -in "$INT_CRT" -noout -subject -enddate -fingerprint -sha256
echo "Target: Secret $SECRET_NS/$SECRET_NAME on $SSH_HOST, via stdin over the admin SSH path."

# Build the Secret YAML in a shell variable and pipe it; base64 output is unwrapped because
# GNU base64 wraps and the YAML data fields must be single-line.
crt_b64="$("$OPENSSL_BIN" base64 -A <"$INT_CRT")"
key_b64="$("$OPENSSL_BIN" base64 -A <"$INT_KEY")"
secret_yaml="$(printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: kubernetes.io/tls\ndata:\n  tls.crt: %s\n  tls.key: %s\n' \
  "$SECRET_NAME" "$SECRET_NS" "$crt_b64" "$key_b64")"

if $DRY_RUN; then
  echo "dry-run: would pipe this Secret (data redacted) to:"
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: kubernetes.io/tls\ndata:\n  tls.crt: <redacted, %s bytes>\n  tls.key: <redacted, %s bytes>\n' \
    "$SECRET_NAME" "$SECRET_NS" "$(wc -c <"$INT_CRT" | tr -d ' ')" "$(wc -c <"$INT_KEY" | tr -d ' ')"
  echo "  ssh $SSH_HOST 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -'"
  exit 0
fi

printf '%s\n' "$secret_yaml" | ssh -o BatchMode=yes "$SSH_HOST" \
  'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -'

echo "Applied. Check (owner, admin path):"
echo "  ssh $SSH_HOST 'sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get clusterissuer lab-ca -o wide'"
echo "  expect Ready once cert-manager reads the Secret; then the wildcard Certificate issues."
