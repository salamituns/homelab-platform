#!/usr/bin/env bash
# Build the Debian 13 cloud-init template (VMID 130) that Terraform clones for Debian-only services (PBS).
# The Ubuntu template 109 was built by hand; this one is a script so it can be rebuilt and reviewed.
#
# 1. Downloads a PINNED Debian cloud image on the Proxmox host and checks it against the SHA-512 below
#    (pinned in git, like a lockfile: a changed file on the mirror fails the build instead of entering it)
# 2. Creates VM 130 with the same hardware shape as template 109
# 3. Boots it once with a vendor-data snippet that installs qemu-guest-agent (Terraform waits for the
#    agent; Debian's image does not ship it), empties machine-id so clones get unique ones, and powers off
# 4. Removes the bake-only settings and converts the VM to a template
#
# It does NOT grant Terraform access to the template; it prints that command for you to run.
# Usage: scripts/build-debian-template.sh        (run from the Mac; uses `ssh tuns`)
set -euo pipefail

PVE_HOST="${PVE_HOST:-tuns}"
VMID=130
NAME=debian13-template
RELEASE=20261021-2638
IMAGE="debian-13-genericcloud-amd64-${RELEASE}.qcow2"
URL="https://cloud.debian.org/images/cloud/trixie/${RELEASE}/${IMAGE}"
SHA512=16e0965312c56feb331049d45d2b1b5778f3f942a33d4300eedbb97527707f2bea87c0006f3e4cc7a25fadbff739c4e235a51fb9bcd1b66fd554f7f8e80ba45c
SNIPPET=debian-template-bake.yaml
TIMEOUT=900

# Variables are meant to expand here, on the Mac, before the command reaches the host.
# shellcheck disable=SC2029
pve() { ssh "$PVE_HOST" "$@"; }

if pve "qm status $VMID" >/dev/null 2>&1; then
  echo "VMID $VMID already exists. Remove it first (qm destroy $VMID) if you mean to rebuild." >&2
  exit 1
fi

echo "Downloading $IMAGE on $PVE_HOST..."
pve "mkdir -p /var/lib/vz/import && cd /var/lib/vz/import && \
     { [ -f '$IMAGE' ] || { curl -q -fsSLo '$IMAGE.part' '$URL' && mv '$IMAGE.part' '$IMAGE'; }; } && \
     echo '$SHA512  $IMAGE' | sha512sum -c -"

# Bake-time only: cloud-init runs this on the single boot, then the snippet is detached.
pve "cat > /var/lib/vz/snippets/$SNIPPET" <<'EOF'
#cloud-config
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable qemu-guest-agent
  - apt-get clean
  # An empty machine-id is regenerated on each clone's first boot; a filled one would be shared by all clones.
  - truncate -s 0 /etc/machine-id
  - rm -f /var/lib/dbus/machine-id
power_state:
  mode: poweroff
  condition: true
EOF

echo "Creating VM $VMID..."
pve "qm create $VMID --name $NAME --ostype l26 --cpu x86-64-v2-AES --cores 2 --memory 2048 \
       --net0 virtio,bridge=vmbr0,firewall=1 --scsihw virtio-scsi-single --agent enabled=1 \
       --serial0 socket --vga serial0 && \
     qm set $VMID --scsi0 local-lvm:0,import-from=/var/lib/vz/import/$IMAGE,iothread=1,discard=on && \
     qm set $VMID --ide2 local-lvm:cloudinit --boot order=scsi0 --ipconfig0 ip=dhcp --ciuser tunsadmin \
       --cicustom vendor=local:snippets/$SNIPPET"

echo "Baking (one boot; installs qemu-guest-agent, then powers off; up to ${TIMEOUT}s)..."
pve "qm start $VMID"
SECONDS=0
until pve "qm status $VMID" | grep -q 'status: stopped'; do
  ((SECONDS > TIMEOUT)) && { echo "Timed out; inspect with: ssh $PVE_HOST qm terminal $VMID" >&2; exit 1; }
  sleep 10
done

echo "Converting to template..."
pve "qm set $VMID --delete cicustom && qm template $VMID && rm -f /var/lib/vz/snippets/$SNIPPET"
pve "qm config $VMID" | grep -E '^(name|template|scsi0|agent|ide2):'

cat <<EOF

Template $VMID ready. Grant the Terraform token clone rights on it (same role as template 109):
  ssh $PVE_HOST pveum acl modify /vms/$VMID --users terraform@pve --roles TerraformClone
EOF
