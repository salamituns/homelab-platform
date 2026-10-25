# ADR 0002: Remote access through a Tailscale subnet router on a dedicated VM

- Status: accepted
- Date: 2026-10-24

## Context
The lab is only reachable from the home LAN. On 2026-10-24 the Mac moved to a phone hotspot
mid-incident and nothing could be reached, including the hypervisor needed to rotate an exposed key.
Gitea is public through a Cloudflare tunnel, but that is for applications, not administration.

## Decision
- **Tailscale (hosted control plane)** for admin access. The Mac app is already installed.
- **Subnet router**, not Tailscale on every host: one node advertises `192.168.1.0/24`, so existing
  IPs, `~/.ssh/config`, the Ansible inventory and Terraform keep working unchanged from anywhere.
- **Dedicated VM `gateway`** (VMID 121, 192.168.1.96, 1 vCPU / 1 GB), built by Terraform and
  hardened by the baseline role. Not on `tuns` (keeps internet-facing agents off the hypervisor)
  and not on `sectools` (one job per VM, smaller blast radius).
- **Tagged device** `tag:homelab-gateway`: owned by the tailnet, no key expiry, not tied to a login.
- **Access policy in git** (`tailscale/policy.hujson`): members may reach the LAN; the gateway may not
  initiate connections to members. Routes are auto-approved only for that exact subnet and tag.
- Auth key: single-use, pre-authorized, tagged, short expiry; lives in `.envrc` only for enrollment.

## Two kinds of remote access (kept separate on purpose)
| Purpose | Tool | Who |
|---|---|---|
| Administration (SSH, Proxmox UI, kubectl) | Tailscale | Only you, authenticated devices |
| Public apps (Gitea) | Cloudflare Tunnel | Anyone on the internet |

## Consequences
- One gateway is a single point of failure for remote access. Mitigation later: a second router,
  or Tailscale directly on `tuns` as break-glass.
- When the Mac is at home it is on the same subnet the gateway advertises. Verify the Mac still
  reaches the LAN directly at home (`tailscale` app: "Use Tailscale subnets" can be left on; check
  with `traceroute 192.168.1.90`).
- Tailscale becomes a third-party dependency for remote admin. Local access is unaffected.

## Amendment 2026-10-25

The members grant was narrowed from `192.168.1.0/24` to the lab's addresses only. The /24 also holds
IoT devices (alarm panel, garage opener, TV), which must not be reachable over the tailnet.
The gateway still advertises the /24; the grant is what limits access.
