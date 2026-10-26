#!/usr/bin/env bash
# Restore drill: prove a PBS backup can become a working VM again (docs/runbooks/backups.md, "Restore drill").
#
# 1. Restores the LATEST backup of <src-vmid> from pbs-store1 as a NEW VM <drill-vmid> (new MACs, --unique)
# 2. Unplugs its network (link_down=1) BEFORE first boot: the copy has the same IP and hostname as the original
# 3. Boots it and talks to it only through the guest agent (a virtual serial cable, no network needed)
# 4. Runs checks inside: for gitea, the service is active and every repository passes `git fsck`
# 5. Prints timings, then stops and destroys the copy (it only ever destroys a VM it created in this run)
#
# Usage: scripts/restore-drill.sh <src-vmid> <drill-vmid> [--keep]     e.g. scripts/restore-drill.sh 122 199
set -euo pipefail

SRC="${1:?usage: $0 <src-vmid> <drill-vmid> [--keep]}"
DRILL="${2:?usage: $0 <src-vmid> <drill-vmid> [--keep]}"
KEEP="${3:-no-keep}"   # never empty: ssh joins args into one string, so "" would vanish
PVE_HOST="${PVE_HOST:-tuns}"
STORAGE=pbs-store1

# Quoted heredoc: runs on tuns as written. Arguments travel positionally.
ssh "$PVE_HOST" bash -s -- "$SRC" "$DRILL" "$KEEP" "$STORAGE" <<'EOF'
set -euo pipefail
src=$1 drill=$2 keep=$3 storage=$4
name="restore-drill-$src"

if qm status "$drill" >/dev/null 2>&1; then
  echo "VMID $drill already exists: pick an unused VMID for the drill." >&2; exit 1
fi
volid="$(pvesm list "$storage" --vmid "$src" | awk 'NR>1{print $1}' | sort | tail -1)"
[[ -n "$volid" ]] || { echo "No backup of VM $src on $storage." >&2; exit 1; }
echo "Backup:   $volid"

t0=$SECONDS
qmrestore "$volid" "$drill" --unique 1 --storage local-lvm >/dev/null
net0="$(qm config "$drill" | awk -F': ' '/^net0:/{print $2}')"
qm set "$drill" --name "$name" --onboot 0 --tags restore-drill --net0 "${net0},link_down=1" >/dev/null
t_restore=$((SECONDS - t0))
echo "Restored: VM $drill in ${t_restore}s (network unplugged)"

cleanup() {
  if [[ "$keep" == "--keep" ]]; then echo "Kept VM $drill (--keep). Remove later: qm stop $drill; qm destroy $drill --purge 1"; return; fi
  # Guard: only destroy the VM this run created and named.
  if qm config "$drill" 2>/dev/null | grep -qx "name: $name"; then
    qm stop "$drill" >/dev/null 2>&1 || true
    qm destroy "$drill" --purge 1 >/dev/null && echo "Cleaned:  VM $drill destroyed"
  fi
}
trap cleanup EXIT

qm start "$drill"
t1=$SECONDS
until qm agent "$drill" ping >/dev/null 2>&1; do
  (( SECONDS - t1 > 300 )) && { echo "Guest agent did not answer within 300s: the restored VM did not boot." >&2; exit 1; }
  sleep 5
done
echo "Booted:   guest agent answered after $((SECONDS - t1))s"

# Run a shell command inside the guest; print its output; return its exit code.
gexec() {
  qm guest exec "$drill" --timeout 120 -- sh -c "$1" | python3 -c '
import sys, json
r = json.load(sys.stdin)
sys.stdout.write(r.get("out-data", "") + r.get("err-data", ""))
sys.exit(r.get("exitcode", 1))'
}

fail=0
check() { if out="$(gexec "$2" 2>&1)"; then echo "  PASS  $1 ${out:+($(echo "$out" | tr '\n' ' ' | sed 's/ *$//'))}"; else echo "  FAIL  $1: $out"; fail=1; fi; }

echo "Checks:"
check "hostname" "hostname"
check "root filesystem mounted rw" "touch /var/tmp/.drill && rm /var/tmp/.drill && echo ok"
case "$src" in
  122)
    sleep 10   # let systemd finish starting units
    check "gitea service active" "systemctl is-active gitea"
    check "repositories pass git fsck" '
      n=0; for r in /var/lib/gitea/data/gitea-repositories/*/*.git; do
        git -c safe.directory="*" -C "$r" fsck --no-progress >/dev/null 2>&1 || { echo "BROKEN $r"; exit 1; }
        n=$((n+1)); done; echo "$n repos"; [ "$n" -gt 0 ]'
    ;;
esac

echo "Total:    $((SECONDS - t0))s from start of restore to checks done"
[[ $fail -eq 0 ]] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }
EOF
