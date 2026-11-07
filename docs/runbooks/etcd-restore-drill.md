# Runbook: etcd snapshot restore drill

Scheduled snapshots: [`ansible/playbooks/k8s-etcd-backup.yml`](../../ansible/playbooks/k8s-etcd-backup.yml)
(timer `00:45 UTC`, `/var/backups/etcd`, 7 days, mode `0700`/`0600`). Apply that playbook
before Level 1, or there is nothing to restore. Whole-VM copies remain PBS
([backups.md](backups.md)); a snapshot without `/etc/kubernetes/pki` and
`enc/encryption-config.yaml` cannot decrypt secretbox Secrets.

`etcdctl` / `etcdutl` live in `registry.k8s.io/etcd:3.5.24-0`. `crictl` is **not**
installed on Master (2026-11-07); the upgrade playbook's `crictl exec` pattern is
the same static pod, reached with `ctr -n k8s.io`.

## 0. Apply the timer (owner)

```sh
cd ansible
ansible-playbook playbooks/k8s-etcd-backup.yml --check --diff
ansible-playbook playbooks/k8s-etcd-backup.yml
```

Optional first snapshot without waiting for 00:45:

```sh
ssh Master 'sudo -n systemctl start k8s-etcd-backup.service && sudo -n ls -l /var/backups/etcd'
```

Rollback: disable the timer and remove the units and directory (this deletes snapshots
on the node; PBS still has VM 108).

```sh
ssh Master 'sudo -n systemctl disable --now k8s-etcd-backup.timer'
# then re-run the playbook after reverting git, or delete the three files by hand
```

## Level 1 — live Master, non-destructive

Restores into `/tmp`, listens on `127.0.0.1:12379` / `12380` only, never moves
`/var/lib/etcd`, never stops kubelet.

```sh
scripts/etcd-restore-drill.sh --dry-run
scripts/etcd-restore-drill.sh
```

Expected: `RESULT: PASS`, namespace and secret counts ≥ 1, `secretbox prefix: PASS`.
Cleanup is a trap: the throwaway container is killed and `/tmp/etcd-restore-drill-<pid>`
is removed even on failure.

If it fails: the live control plane is unchanged. Inspect `ctr -n k8s.io tasks ls` for a
leftover `etcd-restore-drill-*` and `rm -rf /tmp/etcd-restore-drill-*` as root.

## Level 2 — owner, optional, new VMID (NIC down)

Mirrors [backups.md](backups.md) restore-drill: restore VM **108** to an **unused** VMID
with the NIC disconnected, then a full etcd restore **inside that copy**. The live Master
stays up. This script will not run `qm`.

Dry-run (list only):

```sh
ssh tuns 'pvesm list pbs-store1 --vmid 108'
ssh tuns 'qm status 198'   # pick a free VMID; Not found is what you want
```

Restore the copy (real write on tuns — owner only):

```sh
ssh tuns bash -s -- 108 198 pbs-store1 <<'EOF'
set -euo pipefail
src=$1 drill=$2 storage=$3
volid="$(pvesm list "$storage" --vmid "$src" | awk 'NR>1{print $1}' | sort | tail -1)"
[[ -n "$volid" ]] || { echo "No backup of VM $src"; exit 1; }
echo "Backup: $volid"
qmrestore "$volid" "$drill" --unique 1 --storage local-lvm
net0="$(qm config "$drill" | awk -F': ' '/^net0:/{print $2}')"
qm set "$drill" --name "etcd-restore-drill-$src" --onboot 0 --tags restore-drill --net0 "${net0},link_down=1"
qm start "$drill"
EOF
```

Wait for the guest agent, then inside the **copy** (not live Master) follow
[etcd-encryption.md](etcd-encryption.md) §5: stop kubelet, park manifests, `etcdutl snapshot restore`
from `/var/backups/etcd` (or the PBS disk's copy of that path), swap data dirs, start kubelet,
confirm `kube-apiserver` is Running. Talk to the guest only through `qm guest exec`.

Cleanup / rollback (destroys only the drill VM if it still has the drill name):

```sh
ssh tuns bash -s -- 198 <<'EOF'
set -euo pipefail
drill=$1
if qm config "$drill" 2>/dev/null | grep -qx "name: etcd-restore-drill-108"; then
  qm stop "$drill" >/dev/null 2>&1 || true
  qm destroy "$drill" --purge 1
  echo "destroyed $drill"
else
  echo "refusing to destroy $drill: name is not etcd-restore-drill-108" >&2
  exit 1
fi
EOF
```

Do not restore over VM 108. Do not plug the copy into the LAN (same IP as live Master).
