#!/usr/bin/env bash
# One-time (and repeatable) setup of OpenBao for BelleShop (ADR 0014 step 3): KV v2 engine,
# Kubernetes auth, the belleshop-read policy, the belleshop role, and the app secrets.
#
# Needs on the Mac: curl, jq, kubectl (reads kube-public/kube-root-ca.crt), and BAO_ADDR,
# BAO_CACERT, BAO_TOKEN exported (see docs/runbooks/openbao.md).
# Idempotent: it skips what already exists. Secrets come from private/belleshop-secrets.env
# (dotenv; never committed) and go to OpenBao over stdin, never argv. It prints statuses,
# never values.
#
# Undo:
#   bao policy delete belleshop-read
#   bao auth disable kubernetes
#   bao secrets disable secret/            # removes secret/belleshop/app with it
set -euo pipefail

ENV_FILE="${OPENBAO_BELLESHOP_ENV_FILE:-private/belleshop-secrets.env}"
OVERWRITE=false
if [[ "${1:-}" == "--overwrite" ]]; then OVERWRITE=true; fi

for var in BAO_ADDR BAO_CACERT BAO_TOKEN; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is not set. Export BAO_ADDR, BAO_CACERT and BAO_TOKEN first (docs/runbooks/openbao.md)." >&2
    exit 1
  fi
done

# Every OpenBao call goes through this wrapper: pinned CA, bearer token, no secret on argv.
# --fail-with-body: on a non-2xx it prints OpenBao's error JSON and fails the script.
bao_api() { curl -q -sS --fail-with-body --cacert "$BAO_CACERT" -H "Authorization: Bearer $BAO_TOKEN" "$@"; }

# --- KV v2 at secret/ ------------------------------------------------------------------------------------
if bao_api "$BAO_ADDR/v1/sys/mounts" 2>/dev/null | jq -e '."secret/".options.version == "2"' >/dev/null 2>&1; then
  echo "kv: kv-v2 already mounted at secret/"
else
  bao_api -X POST "$BAO_ADDR/v1/sys/mounts/secret" -H 'Content-Type: application/json' \
    --data-binary @- <<< '{"type":"kv-v2"}' >/dev/null
  echo "kv: enabled kv-v2 at secret/"
fi

# --- Kubernetes auth --------------------------------------------------------------------------------------
if bao_api "$BAO_ADDR/v1/sys/auth" 2>/dev/null | jq -e '."kubernetes/"' >/dev/null 2>&1; then
  echo "auth: kubernetes/ already enabled"
else
  bao_api -X POST "$BAO_ADDR/v1/sys/auth/kubernetes" -H 'Content-Type: application/json' \
    --data-binary @- <<< '{"type":"kubernetes"}' >/dev/null
  echo "auth: enabled kubernetes/"
fi

# The cluster CA comes from the ConfigMap the API server publishes; the reviewer JWT is
# deliberately absent: OpenBao calls TokenReview with the client's own ServiceAccount JWT
# (disable_local_ca_jwt below, ADR 0014), so nothing long-lived is stored in OpenBao.
CA_PEM="$(kubectl -n kube-public get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}')"
if [[ -z "$CA_PEM" ]]; then
  echo "ERROR: no CA found in ConfigMap kube-public/kube-root-ca.crt." >&2
  exit 1
fi
config_json="$(jq -n \
  --arg host "https://192.168.1.90:6443" \
  --arg ca "$CA_PEM" \
  '{kubernetes_host: $host, kubernetes_ca_cert: $ca, disable_local_ca_jwt: true}')"
printf '%s' "$config_json" | bao_api -X POST "$BAO_ADDR/v1/auth/kubernetes/config" \
  -H 'Content-Type: application/json' --data-binary @- >/dev/null
echo "auth: kubernetes/ configured (host, CA from kube-public, no reviewer token)"

# --- Policy and role ---------------------------------------------------------------------------------------
bao_api -X PUT "$BAO_ADDR/v1/sys/policies/acl/belleshop-read" -H 'Content-Type: application/json' \
  --data-binary @- <<'POLICY' >/dev/null
{"policy": "path \"secret/data/belleshop/*\" {\n  capabilities = [\"read\"]\n}\n"}
POLICY
echo "policy: belleshop-read written (read-only on secret/data/belleshop/*)"

role_json="$(jq -n \
  --arg sa "eso-belleshop" \
  --arg ns "dev" \
  '{bound_service_account_names: [$sa], bound_service_account_namespaces: [$ns], token_policies: ["belleshop-read"], token_ttl: "1h"}')"
printf '%s' "$role_json" | bao_api -X POST "$BAO_ADDR/v1/auth/kubernetes/role/belleshop" \
  -H 'Content-Type: application/json' --data-binary @- >/dev/null
echo "role: belleshop written (SA eso-belleshop in dev, policy belleshop-read, ttl 1h)"

# --- App secrets: skip if present unless --overwrite -------------------------------------------------------
if bao_api "$BAO_ADDR/v1/secret/data/belleshop/app" >/dev/null 2>&1; then
  if [[ "$OVERWRITE" == false ]]; then
    echo "secrets: secret/belleshop/app already present; keeping it (pass --overwrite to replace)"
    exit 0
  fi
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found (set OPENBAO_BELLESHOP_ENV_FILE to override)." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
missing=()
for key in MYSQL_APP_USER MYSQL_APP_PASSWORD MYSQL_ROOT_PASSWORD SECRET_KEY; do
  [[ -n "${!key:-}" ]] || missing+=("$key")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: $ENV_FILE is missing or empty: ${missing[*]}" >&2
  exit 1
fi

# Over stdin, never argv: the values travel pipe-to-TLS, not through ps or shell history.
secrets_json="$(jq -n \
  --arg user "$MYSQL_APP_USER" \
  --arg password "$MYSQL_APP_PASSWORD" \
  --arg root_password "$MYSQL_ROOT_PASSWORD" \
  --arg secret_key "$SECRET_KEY" \
  '{data: {MYSQL_USER: $user, MYSQL_PASSWORD: $password, MYSQL_ROOT_PASSWORD: $root_password, SECRET_KEY: $secret_key, MYSQL_DATABASE: "belle_shop"}}')"
printf '%s' "$secrets_json" | bao_api -X POST "$BAO_ADDR/v1/secret/data/belleshop/app" \
  -H 'Content-Type: application/json' --data-binary @- >/dev/null
echo "secrets: loaded into secret/belleshop/app (5 keys; values not shown)"
