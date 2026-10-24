#!/usr/bin/env bash
# Safely trust a new Terraform-built VM's SSH host key.
#
# 1. Waits for cloud-init to finish (via the Proxmox guest agent, which works before SSH is up)
# 2. Waits for port 22
# 3. Compares the host key seen over the network with the key read from INSIDE the VM
# 4. Writes to ~/.ssh/known_hosts ONLY if the fingerprints match; otherwise exits non-zero
#
# Usage: scripts/trust-host-key.sh <ip> <vmid>     e.g. scripts/trust-host-key.sh 192.168.1.95 120
set -euo pipefail

IP="${1:?usage: $0 <ip> <vmid>}"
VMID="${2:?usage: $0 <ip> <vmid>}"
PVE_HOST="${PVE_HOST:-tuns}"
TIMEOUT=600

guest_exec() {
  ssh "$PVE_HOST" "qm guest exec $VMID -- $*" |
    python3 -c 'import sys,json; print(json.load(sys.stdin).get("out-data","").strip())'
}

echo "Waiting for cloud-init on VM $VMID (up to ${TIMEOUT}s)..."
SECONDS=0
# "done" = finished (exit 2 "degraded done" is fine: Proxmox's generated config triggers deprecation
# warnings). "disabled" = cloud-init turned off on older hand-built VMs; nothing to wait for.
until guest_exec cloud-init status 2>/dev/null | grep -qE 'status: (done|disabled)'; do
  ((SECONDS > TIMEOUT)) && { echo "Timed out waiting for cloud-init" >&2; exit 1; }
  sleep 5
done
echo "cloud-init: done"

echo "Waiting for $IP:22..."
until nc -z -G 3 "$IP" 22 2>/dev/null; do
  ((SECONDS > TIMEOUT)) && { echo "Timed out waiting for port 22" >&2; exit 1; }
  sleep 3
done

network_line="$(ssh-keyscan -t ed25519 "$IP" 2>/dev/null | grep -v '^#' || true)"
[[ -n "$network_line" ]] || { echo "ssh-keyscan returned no key" >&2; exit 1; }

network_fp="$(ssh-keygen -lf - <<<"$network_line" | awk '{print $2}')"
guest_fp="$(guest_exec cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-keygen -lf - | awk '{print $2}')"

echo "network : $network_fp"
echo "in-guest: $guest_fp"

if [[ -z "$guest_fp" || "$network_fp" != "$guest_fp" ]]; then
  echo "MISMATCH: not trusting $IP. Something else may be answering on this IP." >&2
  exit 1
fi

ssh-keygen -R "$IP" >/dev/null 2>&1 || true
echo "$network_line" >> ~/.ssh/known_hosts
echo "MATCH: $IP added to known_hosts"
