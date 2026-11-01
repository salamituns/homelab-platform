#!/usr/bin/env bash
# Issue a short-lived Kubernetes client certificate for daily access (ADR 0014 step 8).
#
# The private key is generated on this machine and never copied. Approval uses the
# admin kubeconfig on the control-plane node over SSH (or a local admin kubeconfig
# when K8S_ACCESS_REMOTE=local). This script never writes ~/.kube/config.
#
# Usage:
#   scripts/k8s-issue-access-cert.sh <username> [group ...]
# Groups default to both allowlisted names. Only belleshop-operators and
# platform-viewers are accepted.
#
# Env:
#   K8S_ACCESS_DIR              default private/k8s-access (gitignored)
#   K8S_ACCESS_EXPIRY_SECONDS   default 28800 (8h); the signer may shorten this
#   K8S_ACCESS_SSH_HOST         default Master (ansible inventory name)
#   K8S_ACCESS_REMOTE           ssh (default) | local
#   K8S_ACCESS_ADMIN_KUBECONFIG local mode only; must not be the output file
#   K8S_ACCESS_API_SERVER       default https://192.168.1.90:6443
#
# Undo:
#   rm -P "$K8S_ACCESS_DIR/<user>.key" "$K8S_ACCESS_DIR/<user>.kubeconfig"
#   # The issued certificate stays valid until its notAfter; deleting the files
#   # does not revoke it. See docs/runbooks/cluster-access.md.
set -euo pipefail

USER_NAME="${1:-}"
if [[ -z "$USER_NAME" || "$USER_NAME" == -* ]]; then
  echo "usage: $0 <username> [group ...]" >&2
  exit 2
fi
shift

ALLOWED_GROUPS=(belleshop-operators platform-viewers)
# Do not name this GROUPS: bash already has a readonly GROUPS array of numeric GIDs.
if [[ $# -gt 0 ]]; then
  CERT_GROUPS=("$@")
else
  CERT_GROUPS=("${ALLOWED_GROUPS[@]}")
fi

bad_chars='/=,+'
if [[ "$USER_NAME" == system:* ]]; then
  echo "ERROR: refusing username $USER_NAME (system: prefix)." >&2
  exit 1
fi
if [[ "$USER_NAME" == *["$bad_chars"]* ]]; then
  echo "ERROR: refusing username $USER_NAME (characters that change the certificate subject)." >&2
  exit 1
fi

is_allowed_group() {
  local g="$1" a
  for a in "${ALLOWED_GROUPS[@]}"; do
    if [[ "$g" == "$a" ]]; then
      return 0
    fi
  done
  return 1
}

for g in "${CERT_GROUPS[@]}"; do
  if [[ "$g" == *["$bad_chars"]* ]]; then
    echo "ERROR: refusing group $g (characters that change the certificate subject)." >&2
    exit 1
  fi
  if ! is_allowed_group "$g"; then
    echo "ERROR: refusing group $g (allowlist is ${ALLOWED_GROUPS[*]})." >&2
    exit 1
  fi
done

DIR="${K8S_ACCESS_DIR:-private/k8s-access}"
EXPIRY="${K8S_ACCESS_EXPIRY_SECONDS:-28800}"
REMOTE="${K8S_ACCESS_REMOTE:-ssh}"
SSH_HOST="${K8S_ACCESS_SSH_HOST:-Master}"
ADMIN_KUBECONFIG="${K8S_ACCESS_ADMIN_KUBECONFIG:-}"
API_SERVER="${K8S_ACCESS_API_SERVER:-}"

KEY="$DIR/${USER_NAME}.key"
KCFG="$DIR/${USER_NAME}.kubeconfig"
CSR_NAME="homelab-access-${USER_NAME}-$(date +%s)"

home_kube="${HOME}/.kube/config"
if [[ "$KCFG" == "$home_kube" ]]; then
  echo "ERROR: refusing to write the current admin kubeconfig path." >&2
  exit 1
fi
if [[ -n "${KUBECONFIG:-}" && "$KCFG" == "$KUBECONFIG" ]]; then
  echo "ERROR: output kubeconfig is KUBECONFIG; pick another path so the admin file is left alone." >&2
  exit 1
fi
if [[ "$REMOTE" == "local" && -n "$ADMIN_KUBECONFIG" && "$ADMIN_KUBECONFIG" == "$KCFG" ]]; then
  echo "ERROR: admin kubeconfig and output kubeconfig are the same file." >&2
  exit 1
fi

admin_kubectl() {
  if [[ "$REMOTE" == "local" ]]; then
    if [[ -n "$ADMIN_KUBECONFIG" ]]; then
      kubectl --kubeconfig "$ADMIN_KUBECONFIG" "$@"
    else
      kubectl "$@"
    fi
  else
    ssh -o BatchMode=yes "$SSH_HOST" "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf $(printf '%q ' "$@")"
  fi
}

cleanup_csr() {
  admin_kubectl delete csr "$CSR_NAME" --ignore-not-found >/dev/null || true
}

mkdir -p "$DIR"
chmod 700 "$DIR"

if [[ -z "$API_SERVER" ]]; then
  if [[ "$REMOTE" == "local" ]]; then
    detect_kcfg="${ADMIN_KUBECONFIG:-${KUBECONFIG:-$home_kube}}"
    API_SERVER="$(kubectl --kubeconfig "$detect_kcfg" config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  else
    API_SERVER="https://192.168.1.90:6443"
  fi
fi

if [[ ! -f "$KEY" ]]; then
  openssl genrsa -out "$KEY" 2048 >/dev/null 2>&1
  chmod 600 "$KEY"
  echo "key: created $KEY (0600)"
else
  chmod 600 "$KEY"
  echo "key: reusing $KEY"
fi

subj="/CN=${USER_NAME}"
for g in "${CERT_GROUPS[@]}"; do
  subj="${subj}/O=${g}"
done

csr_pem="$(openssl req -new -key "$KEY" -subj "$subj")"
csr_b64="$(printf '%s' "$csr_pem" | openssl base64 -A)"

csr_json="$(jq -n \
  --arg name "$CSR_NAME" \
  --arg req "$csr_b64" \
  --argjson exp "$EXPIRY" \
  '{
    apiVersion: "certificates.k8s.io/v1",
    kind: "CertificateSigningRequest",
    metadata: {name: $name},
    spec: {
      request: $req,
      signerName: "kubernetes.io/kube-apiserver-client",
      expirationSeconds: $exp,
      usages: ["client auth"]
    }
  }')"

# Before the first API call, so a failed approve or issue still removes the CSR.
trap cleanup_csr EXIT

printf '%s' "$csr_json" | admin_kubectl apply -f - >/dev/null
echo "csr: created $CSR_NAME (signer kubernetes.io/kube-apiserver-client, requested ${EXPIRY}s)"

admin_kubectl certificate approve "$CSR_NAME" >/dev/null
echo "csr: approved on the control-plane"

cert_b64=""
for _ in $(seq 1 30); do
  cert_b64="$(admin_kubectl get csr "$CSR_NAME" -o jsonpath='{.status.certificate}' 2>/dev/null || true)"
  if [[ -n "$cert_b64" ]]; then
    break
  fi
  sleep 1
done
if [[ -z "$cert_b64" ]]; then
  echo "ERROR: signer did not issue a certificate for $CSR_NAME." >&2
  exit 1
fi

cert_pem="$(printf '%s' "$cert_b64" | openssl base64 -d -A)"
not_after="$(printf '%s' "$cert_pem" | openssl x509 -noout -enddate)"
echo "cert: issued; ${not_after}"

ca_pem=""
if [[ "$REMOTE" == "local" ]]; then
  kcfg_admin="$ADMIN_KUBECONFIG"
  if [[ -z "$kcfg_admin" ]]; then
    kcfg_admin="${KUBECONFIG:-$home_kube}"
  fi
  ca_pem="$(python3 - "$kcfg_admin" <<'PY'
import base64, os, sys, yaml
from pathlib import Path
cfg = yaml.safe_load(Path(sys.argv[1]).read_text())
cl = cfg["clusters"][0]["cluster"]
if "certificate-authority-data" in cl:
    sys.stdout.buffer.write(base64.b64decode(cl["certificate-authority-data"]))
elif "certificate-authority" in cl:
    sys.stdout.buffer.write(Path(os.path.expanduser(cl["certificate-authority"])).read_bytes())
PY
)"
else
  ca_pem="$(ssh -o BatchMode=yes "$SSH_HOST" 'sudo cat /etc/kubernetes/pki/ca.crt')"
fi

umask 077
tmp_ca="$(mktemp)"
tmp_cert="$(mktemp)"
trap 'rm -f "$tmp_ca" "$tmp_cert"; cleanup_csr' EXIT
printf '%s' "$ca_pem" >"$tmp_ca"
printf '%s' "$cert_pem" >"$tmp_cert"

rm -f "$KCFG"
kubectl config --kubeconfig "$KCFG" set-cluster homelab \
  --server="$API_SERVER" \
  --certificate-authority="$tmp_ca" \
  --embed-certs=true >/dev/null
kubectl config --kubeconfig "$KCFG" set-credentials "$USER_NAME" \
  --client-certificate="$tmp_cert" \
  --client-key="$KEY" \
  --embed-certs=true >/dev/null
kubectl config --kubeconfig "$KCFG" set-context homelab \
  --cluster=homelab \
  --user="$USER_NAME" >/dev/null
kubectl config --kubeconfig "$KCFG" use-context homelab >/dev/null
chmod 600 "$KCFG" "$KEY"
echo "kubeconfig: wrote $KCFG (current admin kubeconfig not modified)"
echo "groups: ${CERT_GROUPS[*]}"

cleanup_csr
echo "csr: removed $CSR_NAME"
trap 'rm -f "$tmp_ca" "$tmp_cert"' EXIT
rm -f "$tmp_ca" "$tmp_cert"
trap - EXIT
