#!/usr/bin/env bash
# Configure OpenBao for OIDC client secrets consumed via External Secrets Operator
# (ADR 0016 decisions 8/5, step 1). Run once per consumer, from the operator's workstation
# against https://bao.home.arpa after minting a short-lived root token (docs/runbooks/openbao.md
# "Minting a short-lived root token"), same as scripts/openbao-setup-alertmanager.sh:
#
#   BAO_ADDR=https://bao.home.arpa \
#   BAO_CACERT=ansible/files/ca/sectools-caddy-root.crt \
#   BAO_TOKEN="$ROOT_TOKEN" \
#     ./scripts/openbao-setup-oidc.sh grafana
#   # ...then revoke the root token immediately:
#   BAO_TOKEN="$ROOT_TOKEN" bao token revoke -self && unset ROOT_TOKEN
#
# What this script does (idempotent; the policy and role are the same on every run, so
# running it for one consumer never undoes another):
#   1. Writes ACL policy `oidc-read`: read-only on the ESO-consumed secret/data/oidc/* paths
#      (grafana + the two oauth2-proxy instances). `oidc/argocd` is deliberately NOT in the
#      policy: Argo CD is out-of-git (ADR 0008) and its client secret is read by the owner
#      over the admin SSH path, so no ESO identity can ever fetch it.
#   2. Writes Kubernetes auth role `oidc` bound exclusively to ServiceAccount `eso-oidc` in
#      namespace `monitoring` (used by SecretStore monitoring/openbao-oidc), 1h tokens.
#   3. Prompts with HIDDEN input for `client_id` and `client_secret` (never echoed, never on
#      argv; sent to OpenBao via stdin). For oauth2-proxy-* consumers it also generates the
#      32-byte cookie_secret itself (openssl, never printed). Skips prompting if the secret
#      already exists unless `--overwrite` is passed.
#
# Undo (per consumer; role and policy shared with the other consumers):
#   curl -qsS --cacert "$BAO_CACERT" -H "X-Vault-Token: $BAO_TOKEN" \
#     -X DELETE "$BAO_ADDR/v1/secret/metadata/oidc/<consumer>"
#   # shared, delete once after ALL consumers are removed:
#   curl -qsS --cacert "$BAO_CACERT" -H "X-Vault-Token: $BAO_TOKEN" \
#     -X DELETE "$BAO_ADDR/v1/auth/kubernetes/role/oidc"
#   curl -qsS --cacert "$BAO_CACERT" -H "X-Vault-Token: $BAO_TOKEN" \
#     -X DELETE "$BAO_ADDR/v1/sys/policies/acl/oidc-read"

set -euo pipefail

DRY_RUN=false
OVERWRITE=false
CONSUMER=""

usage() {
  cat <<'EOF'
Usage: openbao-setup-oidc.sh <consumer> [--dry-run] [--overwrite]

Consumer (one of, from ADR 0016 decision 8):
  grafana                    Grafana generic_oauth client (ESO-synced)
  argocd                     Argo CD OIDC client (owner-read over the admin SSH path)
  oauth2-proxy-prometheus    oauth2-proxy in front of the Prometheus UI (ESO-synced)
  oauth2-proxy-alertmanager  oauth2-proxy in front of the Alertmanager UI (ESO-synced)

Options:
  --dry-run    Print the OpenBao API calls and payloads (with redacted secrets) without
               contacting OpenBao or requiring BAO_TOKEN.
  --overwrite  Prompt for and overwrite secret/data/oidc/<consumer> even if it already
               exists (rotate the Gitea OAuth2 app secret first, then re-run).
  -h, --help   Show this help text.

Environment (required unless --dry-run):
  BAO_ADDR     OpenBao base URL (e.g. https://bao.home.arpa)
  BAO_CACERT   Path to CA certificate file (required when BAO_ADDR uses https://;
               e.g. ansible/files/ca/sectools-caddy-root.crt)
  BAO_TOKEN    Short-lived OpenBao root/admin token (never passed on process argv)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --overwrite)
      OVERWRITE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    grafana|argocd|oauth2-proxy-prometheus|oauth2-proxy-alertmanager)
      if [[ -n "$CONSUMER" ]]; then
        echo "ERROR: consumer given twice: $CONSUMER and $1" >&2
        exit 2
      fi
      CONSUMER="$1"
      shift
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$CONSUMER" ]]; then
  echo "ERROR: missing consumer argument" >&2
  usage >&2
  exit 2
fi

for cmd in curl jq openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found in PATH" >&2
    exit 1
  fi
done

case "$CONSUMER" in
  oauth2-proxy-*) WANTS_COOKIE_SECRET=true ;;
  *)              WANTS_COOKIE_SECRET=false ;;
esac

POLICY_NAME="oidc-read"
K8S_ROLE_NAME="oidc"
BOUND_SA_NAME="eso-oidc"
BOUND_SA_NAMESPACE="monitoring"
KV_SECRET_PATH="oidc/${CONSUMER}"

# Fixed policy content on every run (all ESO-consumed OIDC paths), so re-running for one
# consumer can never drop another consumer's access.
read -r -d '' POLICY_HCL <<'EOF' || true
# Least-privilege read policy for ESO OIDC client secrets in namespace monitoring (ADR 0016
# step 1; consumers are ExternalSecret grafana-oidc today, the two oauth2-proxy instances of
# ADR 0016 step 3 later). secret/data/oidc/argocd is NOT here on purpose: the owner reads it
# over the admin SSH path (Argo CD is out-of-git, ADR 0008).
# KV v2 places secret values under secret/data/<path>.
path "secret/data/oidc/grafana" {
  capabilities = ["read"]
}
path "secret/data/oidc/oauth2-proxy-prometheus" {
  capabilities = ["read"]
}
path "secret/data/oidc/oauth2-proxy-alertmanager" {
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
  if [[ "$WANTS_COOKIE_SECRET" == "true" ]]; then
    echo '[dry-run] {'
    echo '[dry-run]   "data": {'
    echo '[dry-run]     "client_id": "<prompted-hidden>",'
    echo '[dry-run]     "client_secret": "<prompted-hidden>",'
    echo '[dry-run]     "cookie_secret": "<generated-32-byte-never-printed>"'
    echo '[dry-run]   }'
    echo '[dry-run] }'
  else
    echo '[dry-run] {'
    echo '[dry-run]   "data": {'
    echo '[dry-run]     "client_id": "<prompted-hidden>",'
    echo '[dry-run]     "client_secret": "<prompted-hidden>"'
    echo '[dry-run]   }'
    echo '[dry-run] }'
  fi
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

echo "==> Writing ACL policy '${POLICY_NAME}' (read-only on the ESO-consumed secret/data/oidc/* paths)"
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
  echo "    Prompting for the Gitea OAuth2 app credentials of consumer '${CONSUMER}'"
  echo "    (values are hidden, sent via stdin, never echoed and never on process argv):"
  read -rs -p "    Client ID (input hidden): " oidc_client_id
  echo >&2
  if [[ -z "$oidc_client_id" ]]; then
    echo "ERROR: client id must not be empty" >&2
    exit 1
  fi
  read -rs -p "    Client Secret (input hidden): " oidc_client_secret
  echo >&2
  if [[ -z "$oidc_client_secret" ]]; then
    echo "ERROR: client secret must not be empty" >&2
    exit 1
  fi

  # Values reach jq through its environment (never argv); the cookie secret is generated
  # locally for the oauth2-proxy consumers and is never printed.
  if [[ "$WANTS_COOKIE_SECRET" == "true" ]]; then
    # oauth2-proxy needs 16/24/32 raw bytes, base64-encoded; 32 bytes is the documented
    # recipe (oauth2-proxy chart README: openssl rand -base64 32 | head -c 32 | base64).
    cookie_secret="$(openssl rand -base64 32 | head -c 32 | base64)"
    status="$(
      OIDC_CLIENT_ID="$oidc_client_id" \
      OIDC_CLIENT_SECRET="$oidc_client_secret" \
      OIDC_COOKIE_SECRET="$cookie_secret" \
      jq -n '{
        data: {
          client_id: env.OIDC_CLIENT_ID,
          client_secret: env.OIDC_CLIENT_SECRET,
          cookie_secret: env.OIDC_COOKIE_SECRET
        }
      }' | bao_api POST "secret/data/${KV_SECRET_PATH}" stdin
    )"
    unset cookie_secret oidc_client_secret
  else
    status="$(
      OIDC_CLIENT_ID="$oidc_client_id" \
      OIDC_CLIENT_SECRET="$oidc_client_secret" \
      jq -n '{
        data: {
          client_id: env.OIDC_CLIENT_ID,
          client_secret: env.OIDC_CLIENT_SECRET
        }
      }' | bao_api POST "secret/data/${KV_SECRET_PATH}" stdin
    )"
    unset oidc_client_secret
  fi
  unset oidc_client_id
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
if [[ "$WANTS_COOKIE_SECRET" == "true" ]]; then
  expected_keys='["client_id","client_secret","cookie_secret"]'
else
  expected_keys='["client_id","client_secret"]'
fi
if [[ "$keys_json" != "$expected_keys" ]]; then
  echo "ERROR: unexpected keys in secret/${KV_SECRET_PATH}: ${keys_json} (expected ${expected_keys})" >&2
  exit 1
fi
echo "    OK: verified keys ${keys_json} at secret/${KV_SECRET_PATH}"
echo "==> Done. Remember to revoke your short-lived root token: bao token revoke -self"
