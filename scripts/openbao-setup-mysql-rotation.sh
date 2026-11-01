#!/usr/bin/env bash
# One-time (and repeatable) setup of OpenBao's database secrets engine for MySQL
# (ADR 0014 step 4): the bao-admin account, the database/ mount, the connection
# config, root-credential rotation, the static role for the app user, and the
# policy path that lets ESO read the rotated password.
#
# Needs on the Mac: curl, jq, kubectl, openssl. BAO_ADDR, BAO_CACERT and
# BAO_TOKEN must be exported (see docs/runbooks/openbao.md). The MySQL root
# password comes from private/belleshop-secrets.env (dotenv; never committed),
# is read by this script and never printed.
#
# Idempotent: it skips what already exists and prints statuses, never values.
# Invariant: while the connection config exists, only OpenBao knows the
# bao-admin password. So the account's password is (re)set only when the
# connection config is absent, followed by rotate-root; a re-run with the
# config in place changes no password at all.
#
# The static role is created ONLY with --create-static-role, because creating
# it starts a clock: OpenBao rotates the app user's password immediately, and
# RETAIN CURRENT PASSWORD keeps the old one valid only until the next rotation
# (24h by default). Running pods and the hand-made belleshop-secrets still hold
# the old password, so the app must be deployed and reading the file mount from
# dev/belleshop-db-eso BEFORE the flag is used; a pod restart does not help.
#
# Secrets never reach a process command line. Every OpenBao call goes through
# the bao_api wrapper below (token in a config file descriptor); every MySQL
# call goes through mysql_exec, which pipes the root password into the pod over
# stdin (sh reads it as the first line and passes it to mysql as MYSQL_PWD; the
# mysql client's own -p prompt cannot be fed from a pipe: it swallows the whole
# stdin buffer, verified 2026-10-31); values that must reach jq travel through
# the environment (env.NAME), which ps cannot see, not through --arg.
#
# Undo (your terminal; the app user's password was rotated, set a new one by hand):
#   bao delete database/static-roles/belleshop   # if the static role exists
#   bao secrets disable database/                # connection config goes with it
#   kubectl -n dev exec -it mysql-0 -- mysql -uroot -p
#     DROP USER 'bao-admin'@'10.244.%';
#     ALTER USER 'belleshop'@'%' IDENTIFIED BY '<your-new-password>';
#   scripts/openbao-setup-belleshop.sh      # rewrites belleshop-read (same two paths)
#
# Overridable for throwaway test setups (local dev bao server + spike namespace):
#   OPENBAO_ROTATION_ENV_FILE  (default private/belleshop-secrets.env)
#   OPENBAO_ROTATION_NS        (default dev)           MySQL pod namespace
#   OPENBAO_ROTATION_POD       (default mysql-0)       MySQL pod name
#   OPENBAO_ROTATION_LB_IP     (default 192.168.1.244) destination in connection_url
#   OPENBAO_ROTATION_ADMIN_HOST (default 10.244.%)     MySQL account host scope
#   OPENBAO_ROTATION_ADMIN_USER (default bao-admin)
#   OPENBAO_ROTATION_MOUNT     (default database)      secrets-engine mount path
#   OPENBAO_ROTATION_CONNECTION (default mysql)        connection-config name
#   OPENBAO_ROTATION_APP_USER  (default belleshop)     static-role DB user
#   OPENBAO_ROTATION_APP_HOST  (default %)             static-role DB host
#   OPENBAO_ROTATION_PERIOD    (default 24h)           static-role rotation period
set -euo pipefail

ENV_FILE="${OPENBAO_ROTATION_ENV_FILE:-private/belleshop-secrets.env}"
CREATE_STATIC_ROLE=false
if [[ "${1:-}" == "--create-static-role" ]]; then CREATE_STATIC_ROLE=true; fi
NS="${OPENBAO_ROTATION_NS:-dev}"
POD="${OPENBAO_ROTATION_POD:-mysql-0}"
LB_IP="${OPENBAO_ROTATION_LB_IP:-192.168.1.244}"
ADMIN_USER="${OPENBAO_ROTATION_ADMIN_USER:-bao-admin}"
# Host scope: kube-proxy (iptables mode) masquerades LoadBalancer traffic to the
# receiving node's own address in its Flannel pod subnet (kube-flannel-ds gives
# each node a /24 out of 10.244.0.0/16), so MySQL sees 10.244.x.y (one address
# per node), never the 192.168.1.x client IP; verified on this cluster
# 2026-10-31 (sectools -> MetalLB .245 appeared as 10.244.3.1). The LB
# source range (192.168.1.95/32 on the mysql-bao Service) stays the real door
# control; this scope is the second layer and matches nothing outside the pod
# CIDR.
ADMIN_HOST="${OPENBAO_ROTATION_ADMIN_HOST:-10.244.%}"
MOUNT="${OPENBAO_ROTATION_MOUNT:-database}"
CONN="${OPENBAO_ROTATION_CONNECTION:-mysql}"
APP_USER="${OPENBAO_ROTATION_APP_USER:-belleshop}"
APP_HOST="${OPENBAO_ROTATION_APP_HOST:-%}"
PERIOD="${OPENBAO_ROTATION_PERIOD:-24h}"

for var in BAO_ADDR BAO_CACERT BAO_TOKEN; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is not set. Export BAO_ADDR, BAO_CACERT and BAO_TOKEN first (docs/runbooks/openbao.md)." >&2
    exit 1
  fi
done

# Pinned CA and the token through a config file descriptor, never argv or ps
# (printf is a shell builtin). --fail-with-body prints OpenBao's error JSON on
# a non-2xx and fails the script. --cacert is ignored by curl for http://
# addresses, which is what a local dev server uses.
bao_api() {
  curl -q -sS --fail-with-body --cacert "$BAO_CACERT" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$BAO_TOKEN") "$@"
}

# --- MySQL access over stdin ---------------------------------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found (set OPENBAO_ROTATION_ENV_FILE to override)." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
if [[ -z "${MYSQL_ROOT_PASSWORD:-}" ]]; then
  echo "ERROR: $ENV_FILE has no MYSQL_ROOT_PASSWORD." >&2
  exit 1
fi

# Runs one SQL batch as root in the MySQL pod. The root password travels as the
# first stdin line; sh's read consumes exactly one line, mysql gets the rest.
mysql_exec() {
  local sql="$1"
  # shellcheck disable=SC2016  # $pw must expand inside the pod, not here
  (printf '%s\n' "$MYSQL_ROOT_PASSWORD"; printf '%s\n' "$sql") \
    | kubectl -n "$NS" exec -i "$POD" -- \
      sh -c 'IFS= read -r pw && MYSQL_PWD="$pw" mysql -uroot --batch --skip-column-names'
}

# Preflight: MySQL reachable, root password valid, app user present (the static
# role below rotates it, so it must already exist).
mysql_exec 'SELECT 1;' >/dev/null
app_count="$(mysql_exec "SELECT COUNT(*) FROM mysql.user WHERE user='${APP_USER}' AND host='${APP_HOST}';")"
if [[ "${app_count// /}" != "1" ]]; then
  echo "ERROR: MySQL has no '${APP_USER}'@'${APP_HOST}' account. Create the app user first (runbook, ADR 0014)." >&2
  exit 1
fi

# --- database/ mount -------------------------------------------------------------------------------------------
if bao_api "$BAO_ADDR/v1/sys/mounts" 2>/dev/null | jq -e --arg m "${MOUNT}/" '.[$m]' >/dev/null 2>&1; then
  echo "mount: ${MOUNT}/ already enabled"
else
  bao_api -X POST "$BAO_ADDR/v1/sys/mounts/${MOUNT}" -H 'Content-Type: application/json' \
    --data-binary @- <<< '{"type":"database"}' >/dev/null
  echo "mount: enabled ${MOUNT}/"
fi

# --- connection config -----------------------------------------------------------------------------------------
if bao_api "$BAO_ADDR/v1/${MOUNT}/config/${CONN}" >/dev/null 2>&1; then
  echo "connection: ${MOUNT}/config/${CONN} already present; keeping it (rotate-root owns the password now)"
  admin_touched=false
else
  # The config is absent, so this run takes the MySQL account over completely.
  # Bootstrap password, generated here, passed to the pod over stdin. rotate-root
  # replaces it immediately, so it is never known anywhere but this pipe.
  # Hex (letters and digits only): the value is interpolated into the mysql DSN,
  # where characters like '/' or '@' would break parsing.
  # (openssl, not "tr | head": head closing the pipe SIGPIPEs tr under pipefail.)
  admin_pw="$(openssl rand -hex 18)"

  admin_count="$(mysql_exec "SELECT COUNT(*) FROM mysql.user WHERE user='${ADMIN_USER}' AND host='${ADMIN_HOST}';")"
  if [[ "${admin_count// /}" == "1" ]]; then
    # Account exists (partial earlier run or hand-made): reset its password to
    # the freshly generated one so this script can configure the connection.
    mysql_exec "ALTER USER '${ADMIN_USER}'@'${ADMIN_HOST}' IDENTIFIED BY '${admin_pw}' REQUIRE SSL;
GRANT CREATE USER ON *.* TO '${ADMIN_USER}'@'${ADMIN_HOST}';" >/dev/null
    echo "mysql: ${ADMIN_USER}@'${ADMIN_HOST}' existed; password reset (OpenBao takes it over)"
  else
    mysql_exec "CREATE USER '${ADMIN_USER}'@'${ADMIN_HOST}' IDENTIFIED BY '${admin_pw}' REQUIRE SSL;
GRANT CREATE USER ON *.* TO '${ADMIN_USER}'@'${ADMIN_HOST}';" >/dev/null
    echo "mysql: created ${ADMIN_USER}@'${ADMIN_HOST}' (REQUIRE SSL, global CREATE USER only; ADR 0014 decision 5)"
  fi
  admin_touched=true

  # root_rotation_statements: needed not to keep REQUIRE SSL (ALTER USER ...
  # IDENTIFIED BY leaves ssl_type alone, asserted below) but because the plugin
  # default targets '{{username}}'@'%', and this account is host-scoped.
  # The password reaches jq through the environment (env.admin_pw): ps shows a
  # process command line, not its environment, and --arg would put the value
  # on jq's argv.
  conn_json="$(admin_pw="$admin_pw" jq -n \
    --arg plugin mysql-database-plugin \
    --arg url "{{username}}:{{password}}@tcp(${LB_IP}:3306)/?tls=skip-verify" \
    --arg user "$ADMIN_USER" \
    --arg rootrot "ALTER USER '{{username}}'@'${ADMIN_HOST}' IDENTIFIED BY '{{password}}'" \
    --argjson allowed "[\"${APP_USER}\"]" \
    '{plugin_name: $plugin, allowed_roles: ($allowed | join(",")), connection_url: $url, username: $user, password: env.admin_pw, root_rotation_statements: [$rootrot]}')"
  printf '%s' "$conn_json" \
    | bao_api -X POST "$BAO_ADDR/v1/${MOUNT}/config/${CONN}" -H 'Content-Type: application/json' \
      --data-binary @- >/dev/null
  echo "connection: configured ${MOUNT}/config/${CONN} (mysql-database-plugin, ${LB_IP}:3306, tls=skip-verify, role ${APP_USER})"
fi

if [[ "$admin_touched" == true ]]; then
  # Rotate the bootstrap password away: from here on only OpenBao knows it.
  bao_api -X POST "$BAO_ADDR/v1/${MOUNT}/rotate-root/${CONN}" >/dev/null
  echo "rotation: root credential rotated; only OpenBao knows the ${ADMIN_USER} password now"

  # Assert REQUIRE SSL survived the rotation (ssl_type enum: '' | ANY | X509 | SPECIFIED).
  ssl_type="$(mysql_exec "SELECT ssl_type FROM mysql.user WHERE user='${ADMIN_USER}' AND host='${ADMIN_HOST}';")"
  if [[ "${ssl_type// /}" != "ANY" ]]; then
    echo "ERROR: REQUIRE SSL did not survive root rotation (ssl_type='${ssl_type}'). Add REQUIRE SSL to root_rotation_statements." >&2
    exit 1
  fi
  echo "rotation: REQUIRE SSL survived (ssl_type=ANY)"
fi

# --- static role for the app user (explicit --create-static-role only) ----------------------------------------
# Creating the role rotates the app password immediately and starts the 24h
# clock: the previous password stops working at the NEXT rotation, and running
# pods plus the hand-made belleshop-secrets still hold it. Only run this once
# the app reads the file mount from dev/belleshop-db-eso (runbook order).
if [[ "$CREATE_STATIC_ROLE" != true ]]; then
  if bao_api "$BAO_ADDR/v1/${MOUNT}/static-roles/${APP_USER}" >/dev/null 2>&1; then
    echo "static-role: ${MOUNT}/static-roles/${APP_USER} already present (clock running; nothing to do)"
  else
    echo "static-role: skipped (pass --create-static-role to create it; read the runbook first)"
  fi
else
  role_json="$(jq -n \
    --arg db "$CONN" \
    --arg user "$APP_USER" \
    --arg stmt "ALTER USER '{{name}}'@'${APP_HOST}' IDENTIFIED BY '{{password}}' RETAIN CURRENT PASSWORD" \
    --arg period "$PERIOD" \
    '{db_name: $db, username: $user, rotation_statements: [$stmt], rotation_period: $period}')"

  if bao_api "$BAO_ADDR/v1/${MOUNT}/static-roles/${APP_USER}" >/dev/null 2>&1; then
    echo "static-role: ${MOUNT}/static-roles/${APP_USER} already present; keeping it"
  else
    printf '%s' "$role_json" \
      | bao_api -X POST "$BAO_ADDR/v1/${MOUNT}/static-roles/${APP_USER}" -H 'Content-Type: application/json' \
        --data-binary @- >/dev/null
    echo "static-role: created ${MOUNT}/static-roles/${APP_USER} (user ${APP_USER}@'${APP_HOST}', RETAIN CURRENT PASSWORD, period ${PERIOD})"
    echo "WARNING: the app password was rotated NOW; the previous one stops working at the next"
    echo "         rotation (in ${PERIOD}). Running pods still use it. The app must read"
    echo "         dev/belleshop-db-eso (ESO syncs it within ~1m) before that deadline;"
    echo "         restarting a pod does not help while it still reads the old env password."
  fi
fi

# --- policy: add the static-creds read path --------------------------------------------------------------------
# Rewrites belleshop-read with BOTH paths: the KV one from
# openbao-setup-belleshop.sh stays, the database one is new (ADR 0014 step 4).
bao_api -X PUT "$BAO_ADDR/v1/sys/policies/acl/belleshop-read" -H 'Content-Type: application/json' \
  --data-binary @- <<'POLICY' >/dev/null
{"policy": "path \"secret/data/belleshop/*\" {\n  capabilities = [\"read\"]\n}\npath \"database/static-creds/belleshop\" {\n  capabilities = [\"read\"]\n}\n"}
POLICY
echo "policy: belleshop-read written (KV secret/data/belleshop/* + database/static-creds/belleshop, read-only)"
