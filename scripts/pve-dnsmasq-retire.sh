#!/usr/bin/env bash
# Retire the stale legacy dnsmasq from the Proxmox host (tuns).
#
# Why: /etc/dnsmasq.d/homelab.conf (created 2026-01-19) serves the retired
# homelab.local domain, listens on 127.0.0.1 and 10.2.6.181 (an address that no
# longer exists on the host), and forwards to 8.8.8.8, 1.1.1.1 and the dead
# 10.2.0.1 gateway. Internal DNS moved to the gateway VM in week 1.5
# (ADR 0004). Nothing uses this instance; since 2026-11-03 the host firewall
# also blocks outside access to it. It is dead weight that answers :53 on
# every interface, so it is being removed deliberately, not left to surprise
# whoever debugs DNS next.
#
# Run ON tuns as root, e.g. from the Mac (dry run first):
#   ssh root@100.81.210.111 'bash -s -- --dry-run' < scripts/pve-dnsmasq-retire.sh
#   ssh root@100.81.210.111 'bash -s'              < scripts/pve-dnsmasq-retire.sh
#
# What it does, in order, after refusing unless it is safe:
#   0. Refuses if PVE SDN is in use (any /cluster/sdn zone: PVE's SDN dns/ipam
#      plumbing drives a dnsmasq; retiring this one would take that with it) or
#      if apt would remove anything besides dnsmasq itself (a PVE package needing
#      it), or if /etc/resolv.conf points at 127.0.0.1 (the host would lose
#      DNS the moment the service stops), or if homelab.conf is already gone.
#   1. Backs up /etc/dnsmasq.d/homelab.conf, /etc/dnsmasq.conf and the live
#      state to /root/homelab-dnsmasq-retire-backup/ (once; never overwritten).
#   2. Moves homelab.conf out of /etc/dnsmasq.d.
#   3. Stops and disables the dnsmasq systemd unit.
# The dnsmasq PACKAGE is left installed; only the legacy config and the service
# are retired. (Verified 2026-11-03: pvesh get /cluster/sdn/zones is empty and
# `apt-get -s remove dnsmasq` removes nothing else, so both guards pass here.)
# Undo: cp /root/homelab-dnsmasq-retire-backup/homelab.conf /etc/dnsmasq.d/ &&
#       systemctl enable --now dnsmasq
set -euo pipefail

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true
CONF=/etc/dnsmasq.d/homelab.conf
BK=/root/homelab-dnsmasq-retire-backup

run() { if $DRY_RUN; then echo "would: $*"; else "$@"; fi; }

echo "== dnsmasq: enabled=$(systemctl is-enabled dnsmasq 2>/dev/null || echo n/a) active=$(systemctl is-active dnsmasq 2>/dev/null || echo n/a)"
echo "== listening on :53:"
ss -tlnp 2>/dev/null | grep -E ':53\b' || echo "    (nothing)"

# --- Guard 0a: PVE SDN must not be using dnsmasq ---------------------------
if command -v pvesh >/dev/null 2>&1; then
  ZONES="$(pvesh get /cluster/sdn/zones --output-format json 2>/dev/null || echo '[]')"
  if [ "$(jq 'length' <<<"$ZONES" 2>/dev/null || echo 0)" -gt 0 ]; then
    echo "REFUSED: PVE SDN zones exist (pvesh get /cluster/sdn/zones):" >&2
    jq -c '.[] | {type, dnszone, ipam}' <<<"$ZONES" >&2 || cat <<<"$ZONES" >&2
    echo "PVE SDN dns/ipam plumbing drives a dnsmasq; retiring this instance would" >&2
    echo "take that with it. Nothing was changed." >&2
    exit 1
  fi
  echo "guard: no PVE SDN zones (dnsmasq not needed by SDN here)"
else
  echo "guard: pvesh not found (not a PVE host?); continuing - check this host is tuns"
fi

# --- Guard 0b: no other package may depend on dnsmasq ----------------------
REMOVES="$(apt-get -s remove dnsmasq 2>/dev/null | grep -c '^Remv ' || true)"
if [ "$REMOVES" -gt 1 ]; then
  echo "REFUSED: apt would remove more than the dnsmasq package itself:" >&2
  apt-get -s remove dnsmasq 2>/dev/null | grep '^Remv ' >&2
  echo "Some installed package needs dnsmasq. Nothing was changed." >&2
  exit 1
fi
echo "guard: only the dnsmasq package itself would be removed (none of it is)"

# --- Guard 0c: the host must not resolve through 127.0.0.1 ------------------
if grep -qE '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.1\b' /etc/resolv.conf; then
  echo "REFUSED: /etc/resolv.conf points at 127.0.0.1, so the host resolves through" >&2
  echo "this dnsmasq. Repoint resolv.conf first. Nothing was changed." >&2
  exit 1
fi
echo "guard: /etc/resolv.conf does not use 127.0.0.1 (host DNS survives the stop)"

# --- Guard 0d: the legacy config must still be there ------------------------
if [ ! -f "$CONF" ]; then
  echo "nothing to retire: $CONF not found (already removed?). Nothing changed."
  exit 0
fi

# --- 1. Backup ---------------------------------------------------------------
if [ ! -d "$BK" ]; then
  run mkdir -p "$BK"
  run cp -a "$CONF" "$BK/"
  [ -f /etc/dnsmasq.conf ] && run cp -a /etc/dnsmasq.conf "$BK/"
  if $DRY_RUN; then
    echo "would: systemctl status dnsmasq --no-pager > $BK/status-before.txt"
  else
    systemctl status dnsmasq --no-pager >"$BK/status-before.txt" 2>&1 || true
  fi
else
  echo "backup exists: $BK (kept)"
fi

# --- 2. Retire the config -----------------------------------------------------
run mv "$CONF" "$BK/homelab.conf.retired"
$DRY_RUN || echo "config moved out of /etc/dnsmasq.d (kept in $BK)"

# --- 3. Stop and disable the service -----------------------------------------
run systemctl stop dnsmasq
run systemctl disable dnsmasq

echo "== after:"
if $DRY_RUN; then
  echo "would report: systemctl is-enabled/is-active dnsmasq (expect disabled/inactive) and no :53 listener"
else
  echo "dnsmasq: enabled=$(systemctl is-enabled dnsmasq 2>/dev/null || true) active=$(systemctl is-active dnsmasq 2>/dev/null || true)"
  ss -tlnp 2>/dev/null | grep -E ':53\b' || echo "no :53 listener (expected)"
fi
echo "Undo: cp $BK/homelab.conf.retired $CONF && systemctl enable --now dnsmasq"
