#!/usr/bin/env bash
# Owner-run Proxmox host firewall (ADR 0015 C). Mac-side; mutates tuns only
# without --dry-run. Never agent-applied.
#
# Trap: pve-firewall auto-allows 22/8006 from alias local_network. Detection
# today is 192.168.1.0/24 (pve-firewall localnet, 2026-11-03), so sectools
# would still pass the negative proof unless that alias is overwritten.
#
# Live (2026-11-03): PVE 9.1.2; systemd units pve-firewall AND proxmox-firewall
# (nftables) are both enabled/active; cluster.fw has enable: 0 so
# `pve-firewall status` is disabled/running; host.fw has no nftables: 1, so the
# iptables backend is the one that will enforce; nft list tables is empty;
# 11 NICs have firewall=1 but no /etc/pve/firewall/<vmid>.fw exists, and VM
# OPTIONS enable defaults to 0, so guest filtering stays off when the
# datacenter flag flips (PVE docs: NIC flag AND the VM enable option).
# Stale 10.2.6.0/24 allows are still in cluster.fw and host.fw — they go away
# here. Single node: no corosync peer. `at` is not installed.
#
# pve-firewall compile / proxmox-firewall compile read /etc/pve on the node.
# There is no --root / offline file mode (man pve-firewall, 9.1.2). Dry-run
# prints the files; a real apply compiles on tuns after writing enable: 0 and
# before arming the timer / flipping enable.
#
# Usage:
#   scripts/pve-firewall-stage.sh --dry-run
#   scripts/pve-firewall-stage.sh --policy ACCEPT   # ADR step 5
#   scripts/pve-firewall-stage.sh --policy DROP     # ADR step 6 (re-uses first backup)
#   scripts/pve-firewall-stage.sh --cancel
set -euo pipefail

PVE_HOST="${PVE_HOST:-tuns}"
MAC_IP="${MAC_IP:-192.168.1.121}"
TS_CIDR="${TS_CIDR:-100.64.0.0/10}"
POLICY="${PVE_FW_POLICY:-ACCEPT}"
UNIT="${PVE_FW_REVERT_UNIT:-homelab-pve-fw-revert}"
BACKUP_DIR="${PVE_FW_BACKUP_DIR:-/root/homelab-pve-fw-backup}"
CLUSTER_FW="/etc/pve/firewall/cluster.fw"
HOST_FW="/etc/pve/nodes/tuns/host.fw"

DRY_RUN=false
CANCEL=false
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=true ;;
    --cancel) CANCEL=true ;;
    --policy=ACCEPT|--policy=DROP) POLICY="${a#--policy=}" ;;
    --policy)
      echo "error: use --policy=ACCEPT or --policy=DROP" >&2; exit 2 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--dry-run|--cancel|--policy=ACCEPT|--policy=DROP]" >&2; exit 2 ;;
  esac
done

ssh_tuns() { ssh -o BatchMode=yes "$PVE_HOST" "$@"; }

if $CANCEL; then
  if $DRY_RUN; then
    echo "would: ssh $PVE_HOST systemctl stop ${UNIT}.timer ${UNIT}.service"
    exit 0
  fi
  ssh_tuns "systemctl stop ${UNIT}.timer ${UNIT}.service 2>/dev/null || true; echo canceled $UNIT"
  exit 0
fi

cluster_fw_body=$(cat <<EOF
[OPTIONS]
enable: 0
policy_in: ${POLICY}
policy_out: ACCEPT

# Overwrite auto-detect (today 192.168.1.0/24) so 22/8006 are not open to the
# whole LAN. Management ipset then adds the Mac and the tailnet CGNAT range.
[ALIASES]
local_network ${MAC_IP}

[IPSET management]
${MAC_IP}
${TS_CIDR}

[RULES]
IN ACCEPT -source +management -p tcp -dport 22
IN ACCEPT -source +management -p tcp -dport 8006
EOF
)

host_fw_body=$(cat <<'EOF'
[OPTIONS]
nftables: 0

[RULES]
EOF
)

revert_body=$(cat <<EOF
#!/bin/bash
# Restore the pre-stage cluster.fw + host.fw and drop iptables rules.
# pve-firewall stop does not survive reboot; neither does this timer — do not reboot.
set -euo pipefail
cp -a ${BACKUP_DIR}/cluster.fw ${CLUSTER_FW}
cp -a ${BACKUP_DIR}/host.fw ${HOST_FW}
pve-firewall stop || true
logger -t homelab-pve-fw-revert "restored ${BACKUP_DIR} and pve-firewall stop"
EOF
)

echo "== pve-firewall-stage policy_in=${POLICY} =="
if $DRY_RUN; then
  echo "read-only localnet on $PVE_HOST:"
  ssh_tuns 'pve-firewall localnet; echo ---; pve-firewall status; grep -E "enable:|nftables:" /etc/pve/firewall/cluster.fw /etc/pve/nodes/tuns/host.fw 2>/dev/null || true' || true
fi

echo "would backup $CLUSTER_FW and $HOST_FW -> $BACKUP_DIR (kept across ACCEPT then DROP)"
echo "cluster.fw:"
printf '%s\n' "$cluster_fw_body"
echo "host.fw (drops stale 10.2.6 rules; nftables stays off so pve-firewall/iptables owns it):"
printf '%s\n' "$host_fw_body"
echo "then: pve-firewall compile (on tuns, no offline --root)"
echo "then: systemd-run --on-active=15m --unit=$UNIT"
echo "then: set cluster.fw enable: 1"
echo "cancel: ssh $PVE_HOST systemctl stop ${UNIT}.timer"
echo "       # or: $0 --cancel"

if $DRY_RUN; then
  echo "revert script:"
  printf '%s\n' "$revert_body"
  echo "note: pve-firewall compile has no offline mode; proxmox-firewall compile also reads /etc/pve."
  echo "11 VMs with NIC firewall=1 and no <vmid>.fw: guest OPTIONS enable default 0, so they stay unfiltered."
  exit 0
fi

if ssh_tuns "systemctl is-active ${UNIT}.timer >/dev/null 2>&1"; then
  echo "error: ${UNIT}.timer is already active; $0 --cancel first (or wait)" >&2
  exit 3
fi

# First apply keeps the original files; a later DROP pass must restore THAT, not ACCEPT.
ssh_tuns "umask 077
  mkdir -p '$BACKUP_DIR'
  if [ ! -f '$BACKUP_DIR/cluster.fw' ]; then cp -a '$CLUSTER_FW' '$BACKUP_DIR/cluster.fw'; fi
  if [ ! -f '$BACKUP_DIR/host.fw' ]; then cp -a '$HOST_FW' '$BACKUP_DIR/host.fw'; fi
"

printf '%s\n' "$cluster_fw_body" | ssh_tuns "cat > $CLUSTER_FW"
printf '%s\n' "$host_fw_body" | ssh_tuns "cat > $HOST_FW"

echo "compile (enable still 0):"
ssh_tuns "pve-firewall compile" | tail -20

printf '%s\n' "$revert_body" | ssh_tuns "umask 077; cat > /root/homelab-pve-fw-revert.sh && chmod 700 /root/homelab-pve-fw-revert.sh"
ssh_tuns "systemd-run --on-active=15m --timer-property=AccuracySec=1s --unit=$UNIT --description='homelab pve-firewall timed revert' /bin/bash /root/homelab-pve-fw-revert.sh"
echo "armed $UNIT. flipping enable: 1"
ssh_tuns "sed -i 's/^enable: 0\$/enable: 1/' $CLUSTER_FW"
ssh_tuns "pve-firewall status || true"
echo "test Mac SSH+UI, then Tailscale SSH+UI, then from sectools SSH and curl :8006 must fail."
echo "cancel: ssh $PVE_HOST systemctl stop ${UNIT}.timer"
