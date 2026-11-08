#!/usr/bin/env bash
# Configure OpenBao per-tenant policy and Kubernetes auth role for <app>-<env>
# (ADR 0019 D1, D6, Phase 0):
#   - Policy `tenant-<app>-<env>` with read-only capabilities on
#     `secret/data/apps/<app>/<env>/*` and `secret/data/platform/nexus-pull` ONLY.
#   - Kubernetes auth role `tenant-<app>-<env>` bound exclusively to ServiceAccount
#     `eso` in namespace `<app>-<env>` with policy `tenant-<app>-<env>` and 1h TTL.
#
# Owner-run from the Mac; defaults to `--dry-run` (pass `--apply` to execute).
# Mirrors scripts/openbao-setup-belleshop.sh:
#   - Requires curl and jq locally, and BAO_ADDR, BAO_CACERT, BAO_TOKEN exported when `--apply`
#     is passed (see docs/runbooks/openbao.md and docs/runbooks/tenant-secrets.md).
#   - BAO_TOKEN reaches curl via a file descriptor (`--config <(...)`), never argv or ps.
#
# Undo:
#   bao delete auth/kubernetes/role/tenant-<app>-<env>
#   bao policy delete tenant-<app>-<env>
set -euo pipefail

DRY_RUN=true
POSITIONAL=()

usage() {
  cat <<'EOF'
Usage: scripts/openbao-tenant.sh <app> <env> [--dry-run] [--apply]

Arguments:
  <app>        Tenant application identifier (must match ^[a-z0-9-]+$, e.g. govgraph)
  <env>        Tenant environment name (must match ^[a-z0-9-]+$, e.g. staging, prod)

Options:
  --dry-run    Print the OpenBao policy and Kubernetes auth role payloads without
               contacting OpenBao (default).
  --apply      Execute against OpenBao (requires BAO_ADDR, BAO_CACERT, BAO_TOKEN).
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
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "ERROR: unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
    *)
      POSITIONAL+=("$arg")
      ;;
  esac
done

if [[ ${#POSITIONAL[@]} -ne 2 ]]; then
  echo "ERROR: expected exactly 2 positional arguments: <app> <env> (got ${#POSITIONAL[@]})." >&2
  usage >&2
  exit 2
fi

APP="${POSITIONAL[0]}"
ENV_NAME="${POSITIONAL[1]}"

if [[ ! "$APP" =~ ^[a-z0-9-]+$ ]]; then
  echo "ERROR: invalid <app> '${APP}': must match ^[a-z0-9-]+$." >&2
  exit 2
fi
if [[ ! "$ENV_NAME" =~ ^[a-z0-9-]+$ ]]; then
  echo "ERROR: invalid <env> '${ENV_NAME}': must match ^[a-z0-9-]+$." >&2
  exit 2
fi

for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found in PATH." >&2
    exit 1
  fi
done

NAMESPACE="${APP}-${ENV_NAME}"
POLICY_NAME="tenant-${APP}-${ENV_NAME}"
ROLE_NAME="tenant-${APP}-${ENV_NAME}"
SA_NAME="eso"

read -r -d '' POLICY_HCL <<EOF || true
path "secret/data/apps/${APP}/${ENV_NAME}/*" {
  capabilities = ["read"]
}
path "secret/data/platform/nexus-pull" {
  capabilities = ["read"]
}
EOF

POLICY_JSON="$(jq -n --arg policy "$POLICY_HCL" '{policy: $policy}')"
ROLE_JSON="$(jq -n \
  --arg sa "$SA_NAME" \
  --arg ns "$NAMESPACE" \
  --arg pol "$POLICY_NAME" \
  '{
    bound_service_account_names: [$sa],
    bound_service_account_namespaces: [$ns],
    token_policies: [$pol],
    token_ttl: "1h"
  }')"

if [[ "$DRY_RUN" == true ]]; then
  BAO_ADDR_DISPLAY="${BAO_ADDR:-https://bao.home.arpa}"
  BAO_ADDR_DISPLAY="${BAO_ADDR_DISPLAY%/}"
  echo "[dry-run] Mode: dry-run (default; pass --apply to execute)"
  echo "[dry-run] Tenant: app=${APP} env=${ENV_NAME} namespace=${NAMESPACE}"
  echo "[dry-run] 1. PUT ${BAO_ADDR_DISPLAY}/v1/sys/policies/acl/${POLICY_NAME}"
  printf '%s\n' "$POLICY_JSON" | jq .
  echo "[dry-run] 2. POST ${BAO_ADDR_DISPLAY}/v1/auth/kubernetes/role/${ROLE_NAME}"
  printf '%s\n' "$ROLE_JSON" | jq .
  echo "[dry-run] Done. No OpenBao calls were made."
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

if ! bao_api "$BAO_ADDR/v1/sys/mounts" 2>/dev/null | jq -e '."secret/".options.version == "2"' >/dev/null 2>&1; then
  echo "ERROR: KV v2 engine is not mounted at secret/ (run scripts/openbao-setup-belleshop.sh first)." >&2
  exit 1
fi
if ! bao_api "$BAO_ADDR/v1/sys/auth" 2>/dev/null | jq -e '."kubernetes/"' >/dev/null 2>&1; then
  echo "ERROR: kubernetes/ auth is not enabled (run scripts/openbao-setup-belleshop.sh first)." >&2
  exit 1
fi

printf '%s' "$POLICY_JSON" | bao_api -X PUT "$BAO_ADDR/v1/sys/policies/acl/${POLICY_NAME}" \
  -H 'Content-Type: application/json' --data-binary @- >/dev/null
echo "policy: ${POLICY_NAME} written (read-only on secret/data/apps/${APP}/${ENV_NAME}/* and secret/data/platform/nexus-pull)"

printf '%s' "$ROLE_JSON" | bao_api -X POST "$BAO_ADDR/v1/auth/kubernetes/role/${ROLE_NAME}" \
  -H 'Content-Type: application/json' --data-binary @- >/dev/null
echo "role: ${ROLE_NAME} written (SA ${SA_NAME} in ${NAMESPACE}, policy ${POLICY_NAME}, ttl 1h)"
