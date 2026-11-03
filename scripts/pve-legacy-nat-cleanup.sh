#!/usr/bin/env bash
# Remove the 10.2.x-era NAT/forward rules from the Proxmox host (tuns).
#
# Why: with pve-firewall enabled, br_netfilter sets bridge-nf-call-iptables=1,
# so bridged VM-to-VM and LAN-to-VM traffic now traverses the host nat table.
# The legacy "-i vmbr0 --dport 80/443 -j DNAT --to 10.2.0.2" rules then hijack
# every new HTTP(S) connection from non-firewalled VMs (the k8s nodes) and from
# the physical LAN to a retired address. Found 2026-11-03 when Argo CD lost Gitea
# at the moment the firewall was enabled.
#
# Run ON tuns as root, e.g. from the Mac:
#   ssh root@100.81.210.111 'bash -s -- --dry-run' < scripts/pve-legacy-nat-cleanup.sh
#   ssh root@100.81.210.111 'bash -s'              < scripts/pve-legacy-nat-cleanup.sh
#
# What it does (live + boot):
#   1. Backs up /etc/iptables.rules, /etc/iptables/rules.v4, /etc/network/interfaces
#      and the live ruleset to /root/homelab-legacy-nat-backup/ (once; never overwritten).
#   2. Deletes only the legacy rules below from the live ruleset (tailscale and
#      pve-firewall chains are untouched).
#   3. Stops them coming back at boot: comments out the post-up iptables-restore line
#      in /etc/network/interfaces, moves rules.v4 aside, disables netfilter-persistent.
#      pve-firewall and tailscaled install their own rules and do not need either.
# Undo: cp the backups back, `systemctl enable netfilter-persistent`,
#       `iptables-restore < /root/homelab-legacy-nat-backup/live-before.txt`.
set -euo pipefail

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true
BK=/root/homelab-legacy-nat-backup

NAT_PRE=(
  "-i vmbr0 -p tcp -m tcp --dport 80 -j DNAT --to-destination 10.2.0.2:80"
  "-i vmbr0 -p tcp -m tcp --dport 443 -j DNAT --to-destination 10.2.0.2:443"
  "-d 50.172.132.202/32 -p tcp -m tcp --dport 80 -j DNAT --to-destination 10.2.0.2:80"
  "-d 50.172.132.202/32 -p tcp -m tcp --dport 443 -j DNAT --to-destination 10.2.0.2:443"
  "-d 50.172.132.202/32 -p tcp -m tcp --dport 22 -j DNAT --to-destination 10.2.0.2:22"
)
NAT_POST=(
  "-d 10.2.0.2/32 -o vmbr0 -p tcp -m tcp --dport 80 -j MASQUERADE"
  "-d 10.2.0.2/32 -o vmbr0 -p tcp -m tcp --dport 443 -j MASQUERADE"
  "-s 10.2.0.0/21 -o vmbr0 -j MASQUERADE"
  "-s 10.20.77.0/24 ! -d 10.20.77.0/24 -j MASQUERADE"
)
FWD=(
  "-d 10.2.0.2/32 -i vmbr0 -o vmbr0 -p tcp -m tcp --dport 80 -j ACCEPT"
  "-d 10.2.0.2/32 -i vmbr0 -o vmbr0 -p tcp -m tcp --dport 443 -j ACCEPT"
)

run() { if $DRY_RUN; then echo "would: $*"; else "$@"; fi; }

del_rule() { # table chain rule...
  local t=$1 c=$2; shift 2
  # shellcheck disable=SC2048,SC2086  # word-splitting the rule spec is intended
  if iptables -t "$t" -C "$c" $* 2>/dev/null; then
    # shellcheck disable=SC2048,SC2086  # word-splitting the rule spec is intended
    run iptables -t "$t" -D "$c" $*
    $DRY_RUN || echo "deleted: -t $t $c $*"
  else
    echo "absent:  -t $t $c $*"
  fi
}

echo "== sysctl bridge-nf-call-iptables: $(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null || echo n/a)"

if [ ! -d "$BK" ]; then
  run mkdir -p "$BK"
  for f in /etc/iptables.rules /etc/iptables/rules.v4 /etc/network/interfaces; do
    [ -e "$f" ] && run cp -a "$f" "$BK/"
  done
  if $DRY_RUN; then echo "would: iptables-save > $BK/live-before.txt"; else iptables-save > "$BK/live-before.txt"; fi
else
  echo "backup exists: $BK (kept)"
fi

for r in "${NAT_PRE[@]}";  do del_rule nat PREROUTING  "$r"; done
for r in "${NAT_POST[@]}"; do del_rule nat POSTROUTING "$r"; done
for r in "${FWD[@]}";      do del_rule filter FORWARD  "$r"; done

# Boot persistence.
if grep -qE '^[[:space:]]*post-up iptables-restore < /etc/iptables.rules' /etc/network/interfaces; then
  run sed -i 's|^\([[:space:]]*\)post-up iptables-restore < /etc/iptables.rules|\1# homelab 2026-11-03 legacy NAT removed: post-up iptables-restore < /etc/iptables.rules|' /etc/network/interfaces
else
  echo "interfaces: no active post-up iptables-restore line"
fi
[ -e /etc/iptables/rules.v4 ] && run mv /etc/iptables/rules.v4 /etc/iptables/rules.v4.legacy-disabled
if systemctl is-enabled netfilter-persistent >/dev/null 2>&1; then
  run systemctl disable netfilter-persistent
fi

echo "== remaining nat rules:"
iptables -t nat -S | grep -vE '^-(P|N) ' || true
