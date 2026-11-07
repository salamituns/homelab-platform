#!/usr/bin/env bash
# Level 1 etcd restore drill: restore the newest snapshot into /tmp, start a
# throwaway etcd on 127.0.0.1:12379, count /registry keys, check secretbox
# prefixes, then delete the temp dir. Never touches /var/lib/etcd or kubelet.
# Level 2 is documented only (PBS to a new VMID); this script will not run qm.
#
# Usage:
#   scripts/etcd-restore-drill.sh --dry-run
#   scripts/etcd-restore-drill.sh
#   scripts/etcd-restore-drill.sh --level2   # print owner commands, do nothing
set -euo pipefail

DRY_RUN=false
LEVEL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --level2) LEVEL=2; shift ;;
    -h|--help)
      echo "usage: $0 [--dry-run] [--level2]" >&2
      exit 0
      ;;
    *) echo "usage: $0 [--dry-run] [--level2]" >&2; exit 2 ;;
  esac
done

if [[ "$LEVEL" -eq 2 ]]; then
  cat <<'EOF'
Level 2 is owner-only and optional. It restores Master's latest PBS backup to a
NEW VMID with the NIC disconnected, then does a full etcd restore there.
This script does not run qm/pvesh. Copy from docs/runbooks/etcd-restore-drill.md
section "Level 2". First command is a list-only dry run on tuns:

  ssh tuns 'pvesm list pbs-store1 --vmid 108'

EOF
  exit 0
fi

# Quoted heredoc: runs on Master as written. Flags travel positionally.
ssh Master bash -s -- "$DRY_RUN" <<'EOF'
set -euo pipefail
dry=$1
workdir="/tmp/etcd-restore-drill-$$"
container="etcd-restore-drill-$$"
image="$(awk '/image:/{print $2; exit}' /etc/kubernetes/manifests/etcd.yaml)"
newest="$(sudo -n ls -1t /var/backups/etcd/etcd-*.db 2>/dev/null | head -1 || true)"

echo "Image:    ${image}"
echo "Snapshot: ${newest:-NONE}"
echo "Workdir:  ${workdir}"
echo "Listen:   http://127.0.0.1:12379 (peer 12380)"

if [[ -z "${newest}" ]]; then
  echo "No snapshot in /var/backups/etcd. Apply ansible/playbooks/k8s-etcd-backup.yml, then either wait for 00:45 UTC or: sudo systemctl start k8s-etcd-backup.service" >&2
  exit 1
fi

if [[ "${dry}" == "true" ]]; then
  echo "DRY-RUN: would copy snapshot, etcdutl snapshot restore into ${workdir}/restored, start throwaway etcd, count /registry, then kill ${container} and rm -rf ${workdir}"
  exit 0
fi

cleanup() {
  sudo -n ctr -n k8s.io task kill --signal SIGKILL "${container}" >/dev/null 2>&1 || true
  sudo -n ctr -n k8s.io tasks rm "${container}" >/dev/null 2>&1 || true
  sudo -n ctr -n k8s.io containers rm "${container}" >/dev/null 2>&1 || true
  sudo -n rm -rf -- "${workdir}"
}
trap cleanup EXIT

sudo -n mkdir -p -- "${workdir}"
sudo -n cp -a -- "${newest}" "${workdir}/etcd.db"
sudo -n chmod 0600 -- "${workdir}/etcd.db"

sudo -n ctr -n k8s.io run --rm --net-host \
  --mount "type=bind,src=${workdir},dst=/drill,options=rbind" \
  "${image}" "${container}-restore" \
  etcdutl snapshot restore /drill/etcd.db \
    --name drill \
    --initial-cluster drill=http://127.0.0.1:12380 \
    --initial-advertise-peer-urls http://127.0.0.1:12380 \
    --data-dir /drill/restored

sudo -n ctr -n k8s.io run -d --net-host \
  --mount "type=bind,src=${workdir},dst=/drill,options=rbind" \
  "${image}" "${container}" \
  etcd --name drill \
    --data-dir /drill/restored \
    --listen-client-urls http://127.0.0.1:12379 \
    --advertise-client-urls http://127.0.0.1:12379 \
    --listen-peer-urls http://127.0.0.1:12380 \
    --advertise-peer-urls http://127.0.0.1:12380

ok=0
for _ in $(seq 1 30); do
  if sudo -n ctr -n k8s.io task exec --exec-id "wait-$$" "${container}" \
      etcdctl --endpoints=http://127.0.0.1:12379 endpoint health >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 1
done
if [[ "${ok}" -ne 1 ]]; then
  echo "throwaway etcd did not become healthy on 127.0.0.1:12379" >&2
  exit 1
fi

etcdctl_q() {
  sudo -n ctr -n k8s.io task exec --exec-id "q-$RANDOM" "${container}" \
    etcdctl --endpoints=http://127.0.0.1:12379 "$@"
}

ns_count="$(etcdctl_q get /registry/namespaces --prefix --keys-only | grep -c '/registry/namespaces/' || true)"
secret_count="$(etcdctl_q get /registry/secrets --prefix --keys-only | grep -c '/registry/secrets/' || true)"
echo "namespaces under /registry: ${ns_count}"
echo "secrets under /registry:    ${secret_count}"
if [[ "${ns_count}" -lt 1 || "${secret_count}" -lt 1 ]]; then
  echo "expected at least one namespace and one secret in the snapshot" >&2
  exit 1
fi

secret_key="$(etcdctl_q get /registry/secrets --prefix --keys-only | grep '/registry/secrets/' | head -1 | tr -d '\r')"
# Prefix only; never print the value.
if etcdctl_q get "${secret_key}" --print-value-only | python3 -c 'import sys; d=sys.stdin.buffer.read(20); sys.exit(0 if d.startswith(b"k8s:enc:secretbox") else 1)'; then
  echo "secretbox prefix: PASS (k8s:enc:secretbox on first secret; value not printed)"
else
  echo "secretbox prefix: FAIL (first secret value is not k8s:enc:secretbox…)" >&2
  exit 1
fi

echo "RESULT: PASS"
EOF
