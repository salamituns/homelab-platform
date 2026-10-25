# ADR 0003: Break-glass access through Tailscale on the hypervisor

- Status: Accepted
- Date: 2026-10-25

## Context

Since [ADR 0002](0002-remote-access-tailscale-subnet-router.md), remote access depends on one VM,
`gateway`. If it is down (bad upgrade, broken sshd, full disk, deleted by a bad `terraform apply`),
the lab is unreachable from outside, which is exactly when remote repair is needed.

## Options

| Option | Independent of `gateway`? | Cost | Risk |
|---|---|---|---|
| A. Tailscale on `tuns`, no routes, narrow grant | Yes | Nothing new to run | Hypervisor joins the tailnet |
| B. Second subnet router VM | Partly (same template, same role, same mistakes) | Another VM to patch | Two equal doors |
| C. Router port forward / router VPN | Yes | Router config outside git | Exposed to the internet |
| D. Nothing (wait until home) | n/a | None | Long outages |

## Decision

**Option A.** Tailscale on the Proxmox host as tagged node `tag:homelab-breakglass`:

- **Routes nothing** and IP forwarding stays off: it is a door to one machine, not to the LAN.
- **Narrow grant**: members may reach only the ports needed for repair (see `tailscale/policy.hujson`).
- From there: the Proxmox UI gives a console to every VM even when its network is broken, and
  `ssh -J` through `tuns` reaches any VM with the Mac's own key (the hypervisor's key is not
  trusted by guests since the [2026-10-24 incident](../postmortems/2026-10-24-hypervisor-key-exposure.md)).
- A policy test ensures `gateway` cannot reach the break-glass node, so one compromised door
  does not open the other.

The hypervisor is **not** baselined by Ansible (it is excluded from `managed`); only the
`tailscale` role runs on it, from `playbooks/breakglass.yml`.

## Consequences

- If `tuns` itself is down, everything is down anyway; break-glass does not need to cover that.
- Still depends on Tailscale's coordination service. A Tailscale outage leaves only the
  Cloudflare tunnel (Gitea only). Accepted for a homelab; a real out-of-band path (IPMI, LTE
  modem) is out of scope.
- The hypervisor now has a second network identity to monitor. Its node key is listed in
  `docs/credentials.md`; removing the device in the admin console closes the door instantly.
- Break-glass that is never tested does not work: the runbook includes a drill.
