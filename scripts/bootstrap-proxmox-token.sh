#!/usr/bin/env bash
# One-time: create a least-privilege Proxmox identity for Terraform and save its token to .envrc.
#
# Blast radius: the token can create/modify/delete VMs ONLY inside pool "terraform",
# clone (not modify) template 109, use local-lvm and vmbr0, and read node status.
# It cannot see or touch VMs 100-111.
#
# Undo:  ssh tuns 'pveum user delete terraform@pve; pveum role delete TerraformProv;
#                  pveum role delete TerraformClone; pveum role delete TerraformNodeRead;
#                  pveum pool delete terraform'
set -euo pipefail

PVE_HOST="${PVE_HOST:-tuns}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENVRC="$REPO_ROOT/.envrc"

if [[ -f "$ENVRC" ]]; then
  echo "$ENVRC already exists; refusing to overwrite. Delete it first to re-bootstrap." >&2
  exit 1
fi

ssh "$PVE_HOST" bash -s <<'REMOTE'
set -euo pipefail
pveum pool add terraform --comment "VMs managed by homelab-platform Terraform"
pveum role add TerraformProv --privs "VM.Allocate,VM.Audit,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.PowerMgmt,VM.GuestAgent.Audit,Datastore.AllocateSpace,Datastore.Audit,Pool.Audit"
pveum role add TerraformClone --privs "VM.Audit,VM.Clone"
pveum role add TerraformNodeRead --privs "Sys.Audit"
pveum user add terraform@pve --comment "Terraform (homelab-platform). Scoped to pool terraform."
pveum acl modify /pool/terraform               --users terraform@pve --roles TerraformProv
pveum acl modify /storage/local-lvm            --users terraform@pve --roles TerraformProv
pveum acl modify /vms/109                      --users terraform@pve --roles TerraformClone
pveum acl modify /sdn/zones/localnetwork/vmbr0 --users terraform@pve --roles PVESDNUser
pveum acl modify /nodes/tuns                   --users terraform@pve --roles TerraformNodeRead
REMOTE

# The secret is shown only once by Proxmox. Write it straight to a 0600 file; never print it.
umask 077
ssh "$PVE_HOST" 'pveum user token add terraform@pve homelab --privsep 0 --comment "homelab-platform laptop" --output-format json' |
  python3 -c '
import json, sys
d = json.load(sys.stdin)
with open(sys.argv[1], "w") as f:
    f.write("export PROXMOX_VE_ENDPOINT=\"https://192.168.1.181:8006/\"\n")
    f.write("export PROXMOX_VE_API_TOKEN=\"%s=%s\"\n" % (d["full-tokenid"], d["value"]))
print("Token created for", d["full-tokenid"], "->", sys.argv[1])
' "$ENVRC"
