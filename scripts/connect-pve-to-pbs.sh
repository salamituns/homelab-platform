#!/usr/bin/env bash
# Register the PBS datastore on the Proxmox host as storage `pbs-store1` (docs/runbooks/backups.md, step 4).
# Run from the Mac. Prerequisite: step 3 done on pbs (user pve@pbs, token pve@pbs!tuns with DatastoreBackup
# on /datastore/store1, secret in /root/pbs-tuns-token.secret).
#
# The token secret goes pbs -> ssh pipe -> /etc/pve/priv/storage/pbs-store1.pw on tuns:
# never on the Mac's disk, never in argv or shell history. The secret file on pbs is shredded at the end.
#
# Usage: scripts/connect-pve-to-pbs.sh
# Variables in ssh command strings are meant to expand here, on the Mac.
# shellcheck disable=SC2029
set -euo pipefail

PVE_HOST="${PVE_HOST:-tuns}"
PBS_SSH="${PBS_SSH:-tunsadmin@192.168.1.98}"
PBS_IP=192.168.1.98
STORAGE=pbs-store1
DATASTORE=store1
TOKEN_ID='pve@pbs!tuns'
SECRET_FILE=/root/pbs-tuns-token.secret

echo "Reading the PBS certificate fingerprint..."
FP="$(ssh "$PBS_SSH" 'sudo proxmox-backup-manager cert info' | awk '/Fingerprint \(sha256\)/{print $3}')"
[[ "$FP" =~ ^([0-9a-f]{2}:){31}[0-9a-f]{2}$ ]] || { echo "Could not read a SHA-256 fingerprint (got: '$FP')" >&2; exit 1; }
echo "  $FP"

ssh "$PBS_SSH" "sudo test -s $SECRET_FILE" || { echo "$SECRET_FILE missing on pbs: redo step 3" >&2; exit 1; }

# Quoted heredoc: nothing below is expanded by the Mac's shell, so the `!` in the token id is safe.
# Values travel as positional arguments to `bash -s` instead.
echo "Adding storage $STORAGE on $PVE_HOST..."
ssh "$PVE_HOST" bash -s -- "$STORAGE" "$PBS_IP" "$DATASTORE" "$TOKEN_ID" "$FP" <<'EOF'
set -euo pipefail
storage=$1 server=$2 datastore=$3 token=$4 fp=$5
if pvesm status --storage "$storage" >/dev/null 2>&1; then
  echo "  $storage already exists, leaving its settings alone"
else
  pvesm add pbs "$storage" --server "$server" --datastore "$datastore" \
    --username "$token" --fingerprint "$fp" --content backup
fi
EOF

# The secret is written AFTER `pvesm add`: adding a PBS storage without --password clears any .pw file.
echo "Streaming the token secret into /etc/pve/priv/storage/$STORAGE.pw..."
ssh "$PBS_SSH" "sudo cat $SECRET_FILE" |
  ssh "$PVE_HOST" "umask 077; mkdir -p /etc/pve/priv/storage && tr -d '\n' > /etc/pve/priv/storage/$STORAGE.pw"

echo "Checking the connection..."
status="$(ssh "$PVE_HOST" "pvesm status --storage $STORAGE" 2>&1 || true)"
echo "$status"
if grep -qw active <<<"$status"; then
  ssh "$PBS_SSH" "sudo shred -u $SECRET_FILE"
  echo "OK: $STORAGE is active; secret file on pbs shredded."
else
  echo "NOT active. Secret file kept on pbs for a retry. Look at: ssh $PVE_HOST 'pvesm status'" >&2
  exit 1
fi
