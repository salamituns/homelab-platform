#!/usr/bin/env bash
# Retires the remote MySQL root account ('root'@'%') once OpenBao's host-scoped
# bao-admin@'10.244.%' owns rotation (ADR 0014 decision 5).
#
# Preconditions checked before this script was written:
#   - Workload manifests (belleshop-deploy): backend connects as MYSQL_USER
#     (belleshop), mysql-0 has no probes, and mysql-init ConfigMap only runs via
#     the local Unix socket during first-time datadir initialization.
#   - OpenBao rotation uses bao-admin@'10.244.%' over the sectools-only .244
#     LoadBalancer Service; scripts/openbao-setup-mysql-rotation.sh uses
#     `kubectl exec` into mysql-0 over the local Unix socket (root@'localhost').
#
# Safety & idempotency:
#   - Reads MYSQL_ROOT_PASSWORD from private/belleshop-secrets.env and pipes it
#     over stdin (never argv, never printed).
#   - Verifies 'root'@'localhost' exists, is unlocked, holds Super_priv +
#     Grant_priv, and is the account that authenticates a local socket login
#     (SELECT CURRENT_USER() = 'root@localhost') BEFORE touching 'root'@'%'.
#   - Idempotent: if 'root'@'%' is already absent, prints status and exits 0.
#
# Undo (recreate 'root'@'%' over stdin via the local socket in mysql-0):
#   (
#     set -a && . private/belleshop-secrets.env && set +a
#     printf '%s\n' "$MYSQL_ROOT_PASSWORD"
#   ) | kubectl -n dev exec -i mysql-0 -- sh -eu -c '
#     IFS= read -r pw
#      esc=$(printf "%s" "$pw" | sed "s/'\''/'\'''\''/g")
#     MYSQL_PWD="$pw" mysql --protocol=socket -h localhost -uroot <<SQL
# CREATE USER IF NOT EXISTS '\''root'\''@'\''%'\'' IDENTIFIED BY '\''${esc}'\'';
# GRANT ALL PRIVILEGES ON *.* TO '\''root'\''@'\''%'\'' WITH GRANT OPTION;
# FLUSH PRIVILEGES;
# SQL
#   '
#
# Overridable for throwaway test pods:
#   BELLESHOP_MYSQL_ENV_FILE (or OPENBAO_ROTATION_ENV_FILE; default private/belleshop-secrets.env)
#   BELLESHOP_MYSQL_NS       (or OPENBAO_ROTATION_NS;       default dev)
#   BELLESHOP_MYSQL_POD      (or OPENBAO_ROTATION_POD;      default mysql-0)
set -euo pipefail

ENV_FILE="${BELLESHOP_MYSQL_ENV_FILE:-${OPENBAO_ROTATION_ENV_FILE:-private/belleshop-secrets.env}}"
NS="${BELLESHOP_MYSQL_NS:-${OPENBAO_ROTATION_NS:-dev}}"
POD="${BELLESHOP_MYSQL_POD:-${OPENBAO_ROTATION_POD:-mysql-0}}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found (set BELLESHOP_MYSQL_ENV_FILE to override)." >&2
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

# Runs one SQL batch as root over the in-pod Unix socket. The root password
# travels as the first stdin line; sh's read consumes that line and passes it
# via MYSQL_PWD so it never appears on argv.
mysql_local_exec() {
  local sql="$1"
  # shellcheck disable=SC2016  # $pw must expand inside the pod, not here
  (printf '%s\n' "$MYSQL_ROOT_PASSWORD"; printf '%s\n' "$sql") \
    | kubectl -n "$NS" exec -i "$POD" -- \
      sh -c 'IFS= read -r pw && MYSQL_PWD="$pw" mysql --protocol=socket -h localhost -uroot --batch --skip-column-names'
}

# --- 1. Confirm root@'localhost' exists, is unlocked, and authenticates local socket connections ---
local_row="$(mysql_local_exec "SELECT COUNT(*), COALESCE(MAX(account_locked), ''), COALESCE(MAX(Super_priv), ''), COALESCE(MAX(Grant_priv), '') FROM mysql.user WHERE user='root' AND host='localhost';")"
read -r local_count local_locked local_super local_grant <<< "$local_row"

if [[ "${local_count:-0}" != "1" ]]; then
  echo "ERROR: 'root'@'localhost' does not exist in ${NS}/${POD}; refusing to drop 'root'@'%'." >&2
  exit 1
fi
if [[ "${local_locked:-}" != "N" || "${local_super:-}" != "Y" || "${local_grant:-}" != "Y" ]]; then
  echo "ERROR: 'root'@'localhost' in ${NS}/${POD} is locked or missing privileges (locked=${local_locked}, Super=${local_super}, Grant=${local_grant}); refusing to drop 'root'@'%'." >&2
  exit 1
fi

current_user="$(mysql_local_exec "SELECT CURRENT_USER();")"
if [[ "${current_user// /}" != "root@localhost" ]]; then
  echo "ERROR: local socket login resolved to '${current_user}', not 'root@localhost'; refusing to drop 'root'@'%'." >&2
  exit 1
fi
echo "preflight: 'root'@'localhost' exists, unlocked, privileged, and authenticates local socket login in ${NS}/${POD}"

# --- 2. Drop root@'%' if present (idempotent) ------------------------------------------------------
remote_count="$(mysql_local_exec "SELECT COUNT(*) FROM mysql.user WHERE user='root' AND host='%';")"
if [[ "${remote_count// /}" == "0" ]]; then
  echo "mysql: 'root'@'%' already absent in ${NS}/${POD}; nothing to do"
else
  mysql_local_exec "DROP USER 'root'@'%'; FLUSH PRIVILEGES;" >/dev/null
  echo "mysql: dropped 'root'@'%' in ${NS}/${POD}"
fi

# --- 3. Post-check: root@'%' is gone and root@'localhost' still works ------------------------------
after_remote="$(mysql_local_exec "SELECT COUNT(*) FROM mysql.user WHERE user='root' AND host='%';")"
after_current="$(mysql_local_exec "SELECT CURRENT_USER();")"
if [[ "${after_remote// /}" != "0" || "${after_current// /}" != "root@localhost" ]]; then
  echo "ERROR: post-check failed (remote_count=${after_remote}, current_user=${after_current})." >&2
  exit 1
fi
root_hosts="$(mysql_local_exec "SELECT host FROM mysql.user WHERE user='root' ORDER BY host;" | paste -sd ',' -)"
echo "verified: 'root'@'%' count=0, local socket login=${after_current}, remaining root hosts=[${root_hosts}]"
