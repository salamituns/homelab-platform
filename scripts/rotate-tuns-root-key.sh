#!/usr/bin/env bash
# Incident 2026-10-24: rotate root@tuns's SSH key pair and remove the old key everywhere on Proxmox.
# See docs/postmortems/2026-10-24-hypervisor-key-exposure.md
#
# Run AFTER ansible/playbooks/incident-2026-10-24-hypervisor-key.yml.
# Must be on the home LAN. Run from the repo root:  scripts/rotate-tuns-root-key.sh
#
# What it does on tuns:
#   1. Destroys the old /root/.ssh/id_rsa (fingerprint OLD_FP) and generates a new one
#   2. Removes the old public key from /etc/pve/priv/authorized_keys and adds the new one
#   3. Replaces the cloud-init SSH keys on templates 109 and 110 with this Mac's public keys
# Safety: aborts before writing if this Mac's key would no longer be authorized.
set -euo pipefail

PVE_HOST="${PVE_HOST:-tuns}"
OLD_FP="SHA256:fZPNfUEZXkP0Dl1aNGJ4dfPA/4fS5uZrl4JAEQfg57c"

# This runs on the Mac and drives tuns over SSH. Copied to tuns, it would read tuns's own keys.
for f in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
  [ -f "$f" ] || { echo "Missing $f. Run this from the Mac (repo root), not on $PVE_HOST." >&2; exit 1; }
done
MAC_KEYS="$(cat ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub)"
MAC_BLOB="$(awk '{print $2}' ~/.ssh/id_rsa.pub)"   # the key this Mac logs into tuns with

ssh -o BatchMode=yes -o ConnectTimeout=5 "$PVE_HOST" true ||
  { echo "Cannot reach $PVE_HOST. Are you on the home LAN?" >&2; exit 1; }

ssh "$PVE_HOST" "OLD_FP='$OLD_FP' MAC_BLOB='$MAC_BLOB' MAC_KEYS='$MAC_KEYS' bash -s" <<'REMOTE'
set -euo pipefail
cd /root/.ssh
AK=/etc/pve/priv/authorized_keys

# 1. Rotate the key pair (idempotent: skips if already rotated)
old_blob="__none__"
if [ "$(ssh-keygen -lf id_rsa.pub | awk '{print $2}')" = "$OLD_FP" ]; then
  old_blob="$(awk '{print $2}' id_rsa.pub)"
  shred -u id_rsa
  rm -f id_rsa.pub
  ssh-keygen -q -t rsa -b 4096 -N '' -C "root@tuns rotated $(date +%F)" -f id_rsa
  echo "Rotated. New key: $(ssh-keygen -lf id_rsa.pub | awk '{print $2}')"
else
  echo "id_rsa is not the old key; skipping rotation."
  old_blob="$(grep -F 'root@tuns' "$AK" | while read -r l; do
    [ "$(echo "$l" | ssh-keygen -lf - | awk '{print $2}')" = "$OLD_FP" ] && echo "$l" | awk '{print $2}'; done || true)"
  [ -n "$old_blob" ] || old_blob="__none__"
fi

# 2. Rebuild authorized_keys: drop the old key, make sure the new one is present.
new_blob="$(awk '{print $2}' id_rsa.pub)"
tmp="$(mktemp)"
grep -vF "$old_blob" "$AK" > "$tmp" || true
grep -qF "$new_blob" "$tmp" || cat id_rsa.pub >> "$tmp"
if ! grep -qF "$MAC_BLOB" "$tmp"; then
  echo "ABORT: the Mac's key would not be authorized after this change. Nothing written." >&2
  rm -f "$tmp"; exit 1
fi
cp "$AK" "/root/authorized_keys.bak-$(date +%F-%H%M)"   # public keys only, safe to keep
cat "$tmp" > "$AK"     # write in place: pmxcfs does not support sed -i style renames well
rm -f "$tmp"
echo "authorized_keys on tuns now:"; ssh-keygen -lf "$AK" | awk '{print "  ", $2, $3}'

# 3. Templates: inject only the Mac's keys
printf '%s\n' "$MAC_KEYS" > /root/template-ssh-keys.pub
for t in 109 110; do qm set "$t" --sshkeys /root/template-ssh-keys.pub >/dev/null && echo "template $t: keys updated"; done
rm -f /root/template-ssh-keys.pub
REMOTE

echo "--- verify from the Mac"
ssh -o BatchMode=yes "$PVE_HOST" true && echo "Mac can still log into $PVE_HOST"
ssh "$PVE_HOST" "ssh-keygen -lf /etc/pve/priv/authorized_keys | grep -c '$OLD_FP' || true" |
  sed 's/^/old key entries in tuns authorized_keys (expect 0): /'
for t in 109 110; do
  ssh "$PVE_HOST" "qm config $t | grep -c 'root%40tuns' || true" | sed "s/^/template $t root@tuns keys (expect 0): /"
done
