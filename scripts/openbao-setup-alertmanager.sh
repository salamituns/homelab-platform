#!/usr/bin/env bash
# Configure OpenBao for Alertmanager email notifications via External Secrets Operator
# (ADR 0015 section D, step 5).
#
# Run from the operator's workstation against https://bao.home.arpa after minting a
# short-lived root token (docs/runbooks/openbao.md "Minting a short-lived root token"):
#
#   1. Generate a one-time pad and start root token generation:
#        OTP=$(bao operator generate-root -generate-otp)
#        NONCE=$(bao operator generate-root -init -otp="$OTP" -format=json | jq -r .nonce)
#   2. Supply 2 of 3 unseal keys (`bao operator generate-root -nonce="$NONCE"`), then decode:
#        ROOT_TOKEN=$(bao operator generate-root -decode="$ENCODED" -otp="$OTP")
#   3. Run this script:
#        BAO_ADDR=https://bao.home.arpa \
#        BAO_CACERT=ansible/files/ca/sectools-caddy-root.crt \
#        BAO_TOKEN="$ROOT_TOKEN" \
#          ./scripts/openbao-setup-alertmanager.sh
#   4. Immediately revoke the root token when done:
#        BAO_TOKEN="$ROOT_TOKEN" bao token revoke -self
#        unset ROOT_TOKEN OTP NONCE ENCODED
#
# What this script does (idempotent):
#   1. Writes ACL policy `alertmanager-read` granting read-only access to
#      `secret/data/monitoring/alertmanager` (cannot read `secret/data/dev/*` or list mounts).
#   2. Writes Kubernetes auth role `alertmanager` bound exclusively to ServiceAccount
#      `eso-alertmanager` in namespace `monitoring`, issuing 1h tokens with `alertmanager-read`.
#   3. Prompts for `username`, `from`, `to` (plain `read -r`) and `password` (`read -rs`,
#      never echoed) and writes `secret/data/monitoring/alertmanager` via stdin (`--data-binary @-`).
#      If the secret already exists, skips prompting unless `--overwrite` is passed.
#
# Undo:
#   curl -qsS --cacert "$BAO_CACERT" -H "X-Vault-Token: $BAO_TOKEN" \
#     -X DELETE "$BAO_ADDR/v1/secret/metadata/monitoring/alertmanager"
#   curl -qsS --cacert "$BAO_CACERT" -H "X-Vault-Token: $BAO_TOKEN" \
#     -X DELETE "$BAO_ADDR/v1/auth/kubernetes/role/alertmanager"
#   curl -qsS --cacert "$BAO_CACERT" -H "X-Vault-Token: $BAO_TOKEN" \
#     -X DELETE "$BAO_ADDR/v1/sys/policies/acl/alertmanager-read"

set -euo pipefail

DRY_RUN=false
OVERWRITE=false

usage() {
  cat <<'EOF'
Usage: openbao-setup-alertmanager.sh [--dry-run] [--overwrite]

Options:
  --dry-run    Print the OpenBao API calls and payloads (with redacted secrets) without
               contacting OpenBao or requiring BAO_TOKEN.
  --overwrite  Prompt for and overwrite secret/data/monitoring/alertmanager even if it
               already exists.
  -h, --help   Show this help text.

Environment (required unless --dry-run):
  BAO_ADDR     OpenBao base URL (e.g. https://bao.home.arpa)
  BAO_CACERT   Path to CA certificate file (required when BAO_ADDR uses https://;
               e.g. ansible/files/ca/sectools-caddy-root.crt)
  BAO_TOKEN    Short-lived OpenBao root/admin token (never passed on process argv)
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=true
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

for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found in PATH" >&2
    exit 1
  fi
done

POLICY_NAME="alertmanager-read"
K8S_ROLE_NAME="alertmanager"
BOUND_SA_NAME="eso-alertmanager"
BOUND_SA_NAMESPACE="monitoring"
KV_SECRET_PATH="monitoring/alertmanager"

read -r -d '' POLICY_HCL <<'EOF' || true
# Least-privilege read policy for Alertmanager ESO sync in namespace monitoring (ADR 0015 D).
# KV v2 places secret values under secret/data/<path>.
path "secret/data/monitoring/alertmanager" {
  capabilities = ["read"]
}
EOF

POLICY_PAYLOAD="$(jq -n --arg policy "$POLICY_HCL" '{policy: $policy}')"
ROLE_PAYLOAD="$(jq -n \
  --arg sa "$BOUND_SA_NAME" \
  --arg ns "$BOUND_SA_NAMESPACE" \
  --arg pol "$POLICY_NAME" \
  '{
    bound_service_account_names: [$sa],
    bound_service_account_namespaces: [$ns],
    token_policies: [$pol],
    token_ttl: "1h"
  }')"

if [[ "$DRY_RUN" == "true" ]]; then
  BAO_ADDR_DISPLAY="${BAO_ADDR:-https://bao.home.arpa}"
  BAO_ADDR_DISPLAY="${BAO_ADDR_DISPLAY%/}"
  echo "[dry-run] Target OpenBao: ${BAO_ADDR_DISPLAY}"
  echo "[dry-run] 1. PUT ${BAO_ADDR_DISPLAY}/v1/sys/policies/acl/${POLICY_NAME}"
  echo "$POLICY_PAYLOAD" | jq .
  echo "[dry-run] 2. POST ${BAO_ADDR_DISPLAY}/v1/auth/kubernetes/role/${K8S_ROLE_NAME}"
  echo "$ROLE_PAYLOAD" | jq .
  echo "[dry-run] 3. POST ${BAO_ADDR_DISPLAY}/v1/secret/data/${KV_SECRET_PATH} (via stdin --data-binary @-)"
  jq -n '{
    data: {
      username: "<prompted-username>",
      password: "<prompted-16-char-app-password-redacted>",
      from: "<prompted-from>",
      to: "<prompted-to>"
    }
  }'
  echo "[dry-run] Done. No network calls were made."
  exit 0
fi

: "${BAO_ADDR:?BAO_ADDR must be set (e.g. https://bao.home.arpa)}"
: "${BAO_TOKEN:?BAO_TOKEN must be set in environment}"
BAO_ADDR="${BAO_ADDR%/}"

CURL_TLS_ARGS=()
if [[ "$BAO_ADDR" == https://* ]]; then
  : "${BAO_CACERT:?BAO_CACERT must be set when BAO_ADDR uses https:// (e.g. ansible/files/ca/sectools-caddy-root.crt)}"
  if [[ ! -r "$BAO_CACERT" ]]; then
    echo "ERROR: BAO_CACERT is not readable: $BAO_CACERT" >&2
    exit 1
  fi
  CURL_TLS_ARGS=(--cacert "$BAO_CACERT")
fi

# Store X-Vault-Token in a 0600 temp curl config file so BAO_TOKEN never appears in process argv.
umask 077
CURL_AUTH_CFG="$(mktemp)"
TMP_RESP="$(mktemp)"
cleanup() {
  rm -f "$CURL_AUTH_CFG" "$TMP_RESP"
}
trap cleanup EXIT
printf 'header = "X-Vault-Token: %s"\n' "$BAO_TOKEN" >"$CURL_AUTH_CFG"

# Helper: bao_api <METHOD> <path> [stdin_Flag]
# Writes response body to $TMP_RESP and prints the HTTP status code on stdout.
bao_api() {
  local method="$1"
  local path="$2"
  local mode="${3:-none}"
  : >"$TMP_RESP"
  if [[ "$mode" == "stdin" ]]; then
    curl -q -sS ${CURL_TLS_ARGS[@]+"${CURL_TLS_ARGS[@]}"} \
      --config "$CURL_AUTH_CFG" \
      -H "Content-Type: application/json" \
      -X "$method" \
      --data-binary @- \
      -o "$TMP_RESP" \
      -w '%{http_code}' \
      "${BAO_ADDR}/v1/${path}"
  else
    curl -q -sS ${CURL_TLS_ARGS[@]+"${CURL_TLS_ARGS[@]}"} \
      --config "$CURL_AUTH_CFG" \
      -X "$method" \
      -o "$TMP_RESP" \
      -w '%{http_code}' \
      "${BAO_ADDR}/v1/${path}"
  fi
}

echo "==> Checking OpenBao health at ${BAO_ADDR}"
status="$(bao_api GET sys/health)"
if [[ "$status" != "200" ]]; then
  echo "ERROR: OpenBao health check returned HTTP ${status} (expected 200 active/unsealed)" >&2
  exit 1
fi
echo "    OK: healthy and unsealed (HTTP 200)"

echo "==> Verifying KV v2 mount at secret/ and Kubernetes auth mount at auth/kubernetes/"
status="$(bao_api GET sys/mounts)"
if [[ "$status" != "200" ]]; then
  echo "ERROR: GET sys/mounts failed with HTTP ${status}" >&2
  exit 1
fi
if ! jq -e '.["secret/"].type == "kv" and .["secret/"].options.version == "2"' "$TMP_RESP" >/dev/null; then
  echo "ERROR: KV v2 engine is not mounted at secret/" >&2
  exit 1
fi
status="$(bao_api GET sys/auth)"
if [[ "$status" != "200" ]]; then
  echo "ERROR: GET sys/auth failed with HTTP ${status}" >&2
  exit 1
fi
if ! jq -e '.["kubernetes/"].type == "kubernetes"' "$TMP_RESP" >/dev/null; then
  echo "ERROR: kubernetes auth method is not enabled at auth/kubernetes/ (run scripts/openbao-setup-belleshop.sh first)" >&2
  exit 1
fi
echo "    OK: secret/ (kv v2) and auth/kubernetes/ present"

echo "==> Writing ACL policy '${POLICY_NAME}' (read-only on secret/data/${KV_SECRET_PATH})"
status="$(printf '%s' "$POLICY_PAYLOAD" | bao_api PUT "sys/policies/acl/${POLICY_NAME}" stdin)"
if [[ "$status" != "200" && "$status" != "204" ]]; then
  echo "ERROR: writing policy ${POLICY_NAME} failed with HTTP ${status}" >&2
  exit 1
fi
echo "    OK: policy '${POLICY_NAME}' written (HTTP ${status})"

echo "==> Writing Kubernetes auth role '${K8S_ROLE_NAME}' (SA ${BOUND_SA_NAMESPACE}/${BOUND_SA_NAME})"
status="$(printf '%s' "$ROLE_PAYLOAD" | bao_api POST "auth/kubernetes/role/${K8S_ROLE_NAME}" stdin)"
if [[ "$status" != "200" && "$status" != "204" ]]; then
  echo "ERROR: writing role ${K8S_ROLE_NAME} failed with HTTP ${status}" >&2
  exit 1
fi
status="$(bao_api GET "auth/kubernetes/role/${K8S_ROLE_NAME}")"
if [[ "$status" != "200" ]]; then
  echo "ERROR: reading back role ${K8S_ROLE_NAME} failed with HTTP ${status}" >&2
  exit 1
fi
jq -e \
  --arg sa "$BOUND_SA_NAME" \
  --arg ns "$BOUND_SA_NAMESPACE" \
  --arg pol "$POLICY_NAME" \
  '.data.bound_service_account_names == [$sa]
   and .data.bound_service_account_namespaces == [$ns]
   and .data.token_policies == [$pol]
   and .data.token_ttl == 3600' "$TMP_RESP" >/dev/null
echo "    OK: role '${K8S_ROLE_NAME}' verified (SA=${BOUND_SA_NAMESPACE}/${BOUND_SA_NAME}, policies=[${POLICY_NAME}], ttl=3600s)"

echo "==> Checking KV v2 secret 'secret/${KV_SECRET_PATH}'"
status="$(bao_api GET "secret/metadata/${KV_SECRET_PATH}")"
if [[ "$status" == "200" && "$OVERWRITE" != "true" ]]; then
  echo "    OK: secret/${KV_SECRET_PATH} already exists (pass --overwrite to replace)"
else
  echo "    Prompting for Alertmanager SMTP credentials (values are sent via stdin and never echoed):"
  read -r -p "    SMTP username (e.g. user@gmail.com): " smtp_username
  if [[ -z "$smtp_username" ]]; then
    echo "ERROR: SMTP username must not be empty" >&2
    exit 1
  fi

  read -r -p "    Alert From address [${smtp_username}]: " smtp_from
  smtp_from="${smtp_from:-$smtp_username}"

  read -r -p "    Alert To address [${smtp_username}]: " smtp_to
  smtp_to="${smtp_to:-$smtp_username}"

  read -rs -p "    Gmail 16-character App Password (input hidden): " smtp_password
  echo >&2
  # Strip spaces if the user pasted the 4x4 grouped representation from Google Account UI.
  smtp_password="${smtp_password// /}"
  if [[ -z "$smtp_password" ]]; then
    echo "ERROR: SMTP password must not be empty" >&2
    exit 1
  fi

  status="$(
    SMTP_USERNAME="$smtp_username" \
    SMTP_PASSWORD="$smtp_password" \
    SMTP_FROM="$smtp_from" \
    SMTP_TO="$smtp_to" \
    jq -n '{
      data: {
        username: env.SMTP_USERNAME,
        password: env.SMTP_PASSWORD,
        from: env.SMTP_FROM,
        to: env.SMTP_TO
      }
    }' | bao_api POST "secret/data/${KV_SECRET_PATH}" stdin
  )"
  unset smtp_password
  if [[ "$status" != "200" && "$status" != "204" ]]; then
    echo "ERROR: writing secret/${KV_SECRET_PATH} failed with HTTP ${status}" >&2
    exit 1
  fi
  version="$(jq -r '.data.version' "$TMP_RESP")"
  echo "    OK: wrote secret/${KV_SECRET_PATH} (version=${version}, HTTP ${status})"
fi

echo "==> Verifying secret/${KV_SECRET_PATH} key set (values not printed)"
status="$(bao_api GET "secret/data/${KV_SECRET_PATH}")"
if [[ "$status" != "200" ]]; then
  echo "ERROR: reading secret/data/${KV_SECRET_PATH} failed with HTTP ${status}" >&2
  exit 1
fi
keys_json="$(jq -c '.data.data | keys | sort' "$TMP_RESP")"
if [[ "$keys_json" != '["from","password","to","username"]' ]]; then
  echo "ERROR: unexpected keys in secret/${KV_SECRET_PATH}: ${keys_json}" >&2
  exit 1
fi
echo "    OK: verified keys ${keys_json} at secret/${KV_SECRET_PATH}"
echo "==> Done. Remember to revoke your short-lived root token: bao token revoke -self"
