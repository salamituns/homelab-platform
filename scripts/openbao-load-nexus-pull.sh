#!/usr/bin/env bash
# Load the Nexus `k8s-pull` imagePullSecret password from nexus (/etc/nexus/secrets/k8s-pull)
# into OpenBao KV v2 at `secret/platform/nexus-pull` (fields `username`, `password`) and
# configure the least-privilege ACL policy (`nexus-pull-read`) and Kubernetes auth roles
# (`nexus-pull-dev`, `nexus-pull-kyverno`, `nexus-pull-argo-rollouts`) for the three existing
# namespaces (ADR 0014, ADR 0019 Phase 0).
#
# Owner-run from the Mac; defaults to `--dry-run` (pass `--apply` to execute).
# Mirrors scripts/openbao-setup-belleshop.sh:
#   - Requires curl and jq locally, and BAO_ADDR, BAO_CACERT, BAO_TOKEN exported when `--apply`
#     is passed (see docs/runbooks/openbao.md and docs/runbooks/tenant-secrets.md).
#   - BAO_TOKEN reaches curl via a file descriptor (`--config <(...)`), never argv or ps.
#   - The `k8s-pull` password streams from `ssh tunsadmin@192.168.1.87 'sudo -n cat /etc/nexus/secrets/k8s-pull'`
#     into `jq -Rs` and OpenBao via stdin (`--data-binary @-`), never argv, never echoed.
#   - Idempotent: skips writing `secret/platform/nexus-pull` if already present unless
#     `--overwrite` is passed.
#
# Undo:
#   bao delete secret/metadata/platform/nexus-pull
#   bao delete auth/kubernetes/role/nexus-pull-dev
#   bao delete auth/kubernetes/role/nexus-pull-kyverno
#   bao delete auth/kubernetes/role/nexus-pull-argo-rollouts
#   bao policy delete nexus-pull-read
set -euo pipefail

DRY_RUN=true
OVERWRITE=false
NEXUS_SSH="${OPENBAO_NEXUS_SSH:-tunsadmin@192.168.1.87}"
NEXUS_SECRET_FILE="/etc/nexus/secrets/k8s-pull"
NEXUS_USER="k8s-pull"
KV_PATH="platform/nexus-pull"
POLICY_NAME="nexus-pull-read"
EXISTING_NAMESPACES=(dev kyverno argo-rollouts)
SA_NAME="eso-nexus-pull"

usage() {
  cat <<'EOF'
Usage: scripts/openbao-load-nexus-pull.sh [--dry-run] [--apply] [--overwrite]

Options:
  --dry-run    Print the SSH command and OpenBao API payloads (with redacted password)
               without contacting Nexus or OpenBao (default).
  --apply      Execute against Nexus and OpenBao (requires BAO_ADDR, BAO_CACERT, BAO_TOKEN).
  --overwrite  Replace secret/platform/nexus-pull even if it already exists in OpenBao.
  -h, --help   Show this help text.

Environment (required with --apply):
  BAO_ADDR     OpenBao base URL (e.g. https://bao.home.arpa)
  BAO_CACERT   Path to sectools Caddy root CA (e.g. ansible/files/ca/sectools-caddy-root.crt)
  BAO_TOKEN    OpenBao token provided by the owner (never passed on process argv)
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=true
      ;;
    --apply|--execute|--no-dry-run)
      DRY_RUN=false
      ;;
    --overwrite)
      OVERWRITE=true
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

for cmd in curl jq ssh; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found in PATH." >&2
    exit 1
  fi
done

read -r -d '' POLICY_HCL <<'EOF' || true
path "secret/data/platform/nexus-pull" {
  capabilities = ["read"]
}
EOF
POLICY_JSON="$(jq -n --arg policy "$POLICY_HCL" '{policy: $policy}')"

if [[ "$DRY_RUN" == true ]]; then
  BAO_ADDR_DISPLAY="${BAO_ADDR:-https://bao.home.arpa}"
  BAO_ADDR_DISPLAY="${BAO_ADDR_DISPLAY%/}"
  echo "[dry-run] Mode: dry-run (default; pass --apply to execute)"
  echo "[dry-run] 1. PUT ${BAO_ADDR_DISPLAY}/v1/sys/policies/acl/${POLICY_NAME}"
  printf '%s\n' "$POLICY_JSON" | jq .
  step=2
  for ns in "${EXISTING_NAMESPACES[@]}"; do
    role_name="nexus-pull-${ns}"
    echo "[dry-run] ${step}. POST ${BAO_ADDR_DISPLAY}/v1/auth/kubernetes/role/${role_name}"
    jq -n \
      --arg sa "$SA_NAME" \
      --arg ns "$ns" \
      --arg pol "$POLICY_NAME" \
      '{
        bound_service_account_names: [$sa],
        bound_service_account_namespaces: [$ns],
        token_policies: [$pol],
        token_ttl: "1h"
      }'
    step=$((step + 1))
  done
  echo "[dry-run] ${step}. Read password via: ssh ${NEXUS_SSH} 'sudo -n cat ${NEXUS_SECRET_FILE}'"
  echo "[dry-run] $((step + 1)). POST ${BAO_ADDR_DISPLAY}/v1/secret/data/${KV_PATH} (via stdin --data-binary @-, overwrite=${OVERWRITE})"
  jq -n --arg user "$NEXUS_USER" '{
    data: {
      username: $user,
      password: "<redacted-from-nexus:/etc/nexus/secrets/k8s-pull>"
    }
  }'
  echo "[dry-run] Done. No SSH or OpenBao calls were made."
  exit 0
fi

for var in BAO_ADDR BAO_CACERT BAO_TOKEN; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is not set. Export BAO_ADDR, BAO_CACERT and BAO_TOKEN first (docs/runbooks/openbao.md)." >&2
    exit 1
  fi
done
BAO_ADDR="${BAO_ADDR%/}"

# Every OpenBao call goes through this wrapper: pinned CA, and the token reaches curl through a
# config file descriptor, so it never appears on argv or in ps (printf is a shell builtin).
# --fail-with-body: on a non-2xx it prints OpenBao's error JSON and fails the script.
bao_api() {
  curl -q -sS --fail-with-body --cacert "$BAO_CACERT" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$BAO_TOKEN") "$@"
}

# --- KV v2 at secret/ and Kubernetes auth check ------------------------------------------------------------
if ! bao_api "$BAO_ADDR/v1/sys/mounts" 2>/dev/null | jq -e '."secret/".options.version == "2"' >/dev/null 2>&1; then
  echo "ERROR: KV v2 engine is not mounted at secret/ (run scripts/openbao-setup-belleshop.sh first)." >&2
  exit 1
fi
if ! bao_api "$BAO_ADDR/v1/sys/auth" 2>/dev/null | jq -e '."kubernetes/"' >/dev/null 2>&1; then
  echo "ERROR: kubernetes/ auth is not enabled (run scripts/openbao-setup-belleshop.sh first)." >&2
  exit 1
fi

# --- Policy and Kubernetes auth roles for existing namespaces (dev, kyverno, argo-rollouts) ----------------
printf '%s' "$POLICY_JSON" | bao_api -X PUT "$BAO_ADDR/v1/sys/policies/acl/${POLICY_NAME}" \
  -H 'Content-Type: application/json' --data-binary @- >/dev/null
echo "policy: ${POLICY_NAME} written (read-only on secret/data/${KV_PATH})"

for ns in "${EXISTING_NAMESPACES[@]}"; do
  role_name="nexus-pull-${ns}"
  role_json="$(jq -n \
    --arg sa "$SA_NAME" \
    --arg ns "$ns" \
    --arg pol "$POLICY_NAME" \
    '{
      bound_service_account_names: [$sa],
      bound_service_account_namespaces: [$ns],
      token_policies: [$pol],
      token_ttl: "1h"
    }')"
  printf '%s' "$role_json" | bao_api -X POST "$BAO_ADDR/v1/auth/kubernetes/role/${role_name}" \
    -H 'Content-Type: application/json' --data-binary @- >/dev/null
  echo "role: ${role_name} written (SA ${SA_NAME} in ${ns}, policy ${POLICY_NAME}, ttl 1h)"
done

# --- Secret secret/platform/nexus-pull: skip if present unless --overwrite ---------------------------------
if bao_api "$BAO_ADDR/v1/secret/data/${KV_PATH}" >/dev/null 2>&1; then
  if [[ "$OVERWRITE" == false ]]; then
    echo "secrets: secret/${KV_PATH} already present; keeping it (pass --overwrite to replace)"
    exit 0
  fi
fi

# Stream the password from nexus over ssh stdin into jq -Rs; never on argv, never echoed.
secrets_json="$(
  ssh -n "$NEXUS_SSH" 'sudo -n cat /etc/nexus/secrets/k8s-pull' \
    | jq -eRs --arg user "$NEXUS_USER" '
        rtrimstr("\r\n") | rtrimstr("\n")
        | if length == 0 then error("empty password read from /etc/nexus/secrets/k8s-pull") else . end
        | {data: {username: $user, password: .}}
      '
)"
printf '%s' "$secrets_json" | bao_api -X POST "$BAO_ADDR/v1/secret/data/${KV_PATH}" \
  -H 'Content-Type: application/json' --data-binary @- >/dev/null
unset secrets_json
echo "secrets: loaded into secret/${KV_PATH} (2 keys: username, password; values not shown)"
