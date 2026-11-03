#!/usr/bin/env bash
# Owner-run iDRAC recovery path (ADR 0015 C, step 1). Runs on the Mac; mutates tuns
# only when you omit --dry-run. The agent must never run this without --dry-run.
#
# Why iDRAC first: noVNC is on :8006, so a bad Proxmox firewall rule cannot recover
# itself. Physical access is not available. Local ipmitool on tuns talks to the BMC
# over /dev/ipmi0, so it still works after the dedicated NIC is abandoned.
#
# Live (2026-11-03, read-only): iDRAC8 fw 2.86, dedicated, static 10.2.6.180/13
# gw 10.2.0.1, active NIC None (dedicated has no cable), only nic0/LOM1 is UP,
# SOL on 115.2, user 2 = root ADMINISTRATOR, racadm not installed, LAN channel 1
# Access Mode disabled (sessions would stay dark even after a new IP).
#
# Password stays off argv: ipmitool `user set password 2 <pw>` puts <pw> in ps.
# This script writes `user set password 2 …` to a 0600 exec file on tuns over
# ssh stdin, runs `ipmitool exec` (argv is only the filename), then shreds the
# file. The password is never a ssh/ipmitool argument.
#
# Usage:
#   scripts/idrac-setup.sh --dry-run
#   printf '%s' "$pw" | scripts/idrac-setup.sh
#   scripts/idrac-setup.sh --password-file /path   # one line, not in git
#   scripts/idrac-setup.sh --cancel                # stop the 15m revert timer
#
# After you can open https://192.168.1.182 from the Mac: --cancel, then the
# firewall script. Revert restores dedicated + the old 10.2.6.180 address only
# (the previous password is not knowable; it is not reverted).
set -euo pipefail

PVE_HOST="${PVE_HOST:-tuns}"
IDRAC_IP="${IDRAC_IP:-192.168.1.182}"          # ping/arp free 2026-11-03; not in dns.yml; outside DHCP .100-.180
IDRAC_NETMASK="${IDRAC_NETMASK:-255.255.255.0}"
IDRAC_GW="${IDRAC_GW:-192.168.1.254}"          # Mac default route
IDRAC_OLD_IP="${IDRAC_OLD_IP:-10.2.6.180}"
IDRAC_OLD_MASK="${IDRAC_OLD_MASK:-255.248.0.0}"
IDRAC_OLD_GW="${IDRAC_OLD_GW:-10.2.0.1}"
IDRAC_USER_ID="${IDRAC_USER_ID:-2}"
MAC_IP="${MAC_IP:-192.168.1.121}"
# 13G iDRAC8: "shared with lom1" is LOM1 and no failover. "shared with Failover None"
# is a sibling token; lom1 is the only cabled NIC (nic0).
IDRAC_NIC_MODE="${IDRAC_NIC_MODE:-shared with lom1}"
IDRAC_NIC_REVERT="${IDRAC_NIC_REVERT:-dedicated}"
UNIT="${IDRAC_REVERT_UNIT:-homelab-idrac-revert}"
REVERT_SH="/root/homelab-idrac-revert.sh"
EXEC_FILE="/root/homelab-idrac-user.exec"

DRY_RUN=false
CANCEL=false
PASS_FILE=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=true ;;
    --cancel) CANCEL=true ;;
    --password-file) echo "error: use --password-file=PATH" >&2; exit 2 ;;
    --password-file=*) PASS_FILE="${a#--password-file=}" ;;
    -h|--help)
      sed -n '2,35p' "$0"
      exit 0 ;;
    *) echo "usage: $0 [--dry-run|--cancel|--password-file=PATH]" >&2; exit 2 ;;
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

if $DRY_RUN; then
  echo "== dry-run: no writes on $PVE_HOST, password not read =="
  echo "live (read-only peek):"
  ssh_tuns 'ipmitool delloem lan get; ipmitool delloem lan get active; ipmitool lan print 1 | egrep "IP Address|Subnet|Default Gateway|IP Address Source"' || true
fi

if ! $DRY_RUN; then
  pw=""
  if [[ -n "$PASS_FILE" ]]; then
    pw=$(head -n1 "$PASS_FILE")
  elif [[ -t 0 ]]; then
    printf 'iDRAC user %s password (not echoed): ' "$IDRAC_USER_ID" >&2
    read -rs pw
    echo >&2
  else
    IFS= read -r pw
  fi
  # iDRAC8 user passwords are 1–20 chars. Spaces would split ipmitool exec tokens.
  if [[ ${#pw} -lt 8 || ${#pw} -gt 20 || "$pw" == *$'\t'* || "$pw" == *' '* ]]; then
    echo "error: password must be 8-20 chars with no spaces (never printed)" >&2
    exit 2
  fi
fi

revert_body=$(cat <<EOF
#!/bin/bash
# Installed by scripts/idrac-setup.sh. Restores dedicated NIC + the previous
# static address. Does not touch the user password (unknown after rotation).
set -euo pipefail
ipmitool delloem lan set ${IDRAC_NIC_REVERT}
ipmitool lan set 1 ipsrc static
ipmitool lan set 1 ipaddr ${IDRAC_OLD_IP}
ipmitool lan set 1 netmask ${IDRAC_OLD_MASK}
ipmitool lan set 1 defgw ipaddr ${IDRAC_OLD_GW}
logger -t homelab-idrac-revert "reverted iDRAC to ${IDRAC_NIC_REVERT} ${IDRAC_OLD_IP}"
EOF
)

echo "plan:"
echo "  1. password via ipmitool exec file $EXEC_FILE (shredded; not argv)"
echo "  2. ipmitool lan set 1 access on   # live Access Mode is disabled"
echo "  3. ipmitool delloem lan set ${IDRAC_NIC_MODE}   # separate words, then verified"
echo "  4. static ${IDRAC_IP}/${IDRAC_NETMASK} gw ${IDRAC_GW}"
echo "  5. IP range filter: skipped unless racadm exists (it does not, 2026-11-03)"
echo "  6. systemd-run --on-active=15m --unit=$UNIT -> $REVERT_SH"
echo "cancel after the Mac can reach https://${IDRAC_IP}/ :"
echo "  ssh $PVE_HOST systemctl stop ${UNIT}.timer"
echo "  # or: $0 --cancel"

if $DRY_RUN; then
  echo "revert script that would be installed at $REVERT_SH:"
  printf '%s\n' "$revert_body"
  echo "would: ssh $PVE_HOST 'command -v racadm && racadm get iDRAC.IPBlocking || echo no racadm'"
  exit 0
fi

# Refuse to stack timers; a second apply would race the first revert.
if ssh_tuns "systemctl is-active ${UNIT}.timer >/dev/null 2>&1"; then
  echo "error: ${UNIT}.timer is already active; $0 --cancel first" >&2
  exit 3
fi

# Password file: stdin of remote cat, never ssh argv.
printf 'user set password %s %s\n' "$IDRAC_USER_ID" "$pw" | ssh_tuns "umask 077; cat > $EXEC_FILE"
pw=""  # drop from this shell
ssh_tuns "ipmitool exec $EXEC_FILE; ec=\$?; shred -u $EXEC_FILE 2>/dev/null || rm -f $EXEC_FILE; exit \$ec"
echo "password set for user $IDRAC_USER_ID (value not printed)"

ssh_tuns "ipmitool lan set 1 access on"

# Arm the revert BEFORE touching NIC mode or address, so any failure from
# here on (or a lost link) is undone by the timer.
printf '%s\n' "$revert_body" | ssh_tuns "umask 077; cat > $REVERT_SH && chmod 700 $REVERT_SH"
ssh_tuns "systemd-run --on-active=15m --timer-property=AccuracySec=1s --unit=$UNIT --description='homelab iDRAC timed revert' /bin/bash $REVERT_SH"
echo "armed $UNIT (15m). Cancel: ssh $PVE_HOST systemctl stop ${UNIT}.timer"

# Unquoted on purpose: ipmitool's delloem parser matches the mode word by
# word (argv "shared" "with" "lom1"); one quoted argument prints usage.
ssh_tuns "ipmitool delloem lan set $IDRAC_NIC_MODE"
got_mode=$(ssh_tuns "ipmitool delloem lan get" | tr -d '\r' | sed '/^$/d' | tail -1)
if [ "$(printf %s "$got_mode" | tr 'A-Z' 'a-z')" != "$(printf %s "$IDRAC_NIC_MODE" | tr 'A-Z' 'a-z')" ]; then
  echo "error: NIC mode is '$got_mode', expected '$IDRAC_NIC_MODE'; address not changed (timer still reverts in 15m; --cancel to drop it)" >&2
  exit 4
fi
echo "NIC mode now: $got_mode"
ssh_tuns "ipmitool lan set 1 ipsrc static"
ssh_tuns "ipmitool lan set 1 ipaddr $IDRAC_IP"
ssh_tuns "ipmitool lan set 1 netmask $IDRAC_NETMASK"
ssh_tuns "ipmitool lan set 1 defgw ipaddr $IDRAC_GW"

# Optional IP range: only if Dell's racadm is present. ipmitool has no IPBlocking.
if ssh_tuns 'command -v racadm >/dev/null'; then
  ssh_tuns "racadm set iDRAC.IPBlocking.RangeEnable 1
    racadm set iDRAC.IPBlocking.RangeAddr $MAC_IP
    racadm set iDRAC.IPBlocking.RangeMask 255.255.255.255
    racadm set iDRAC.IPBlocking.BlockEnable 1"
  echo "racadm IP range limited to $MAC_IP/32"
else
  echo "note: racadm absent; set iDRAC IP Range in the web UI to $MAC_IP after you get in"
fi

echo "test from the Mac: curl -qk https://${IDRAC_IP}/  (and the web UI). Then --cancel."
echo "SOL (optional, owner, separate from this timer — a reboot would kill the timer):"
echo "  kernel console=ttyS1,115200n8 and systemctl enable --now serial-getty@ttyS1"
echo "  (do not change GRUB as part of this apply)"
