# Entry points into the lab

Every way to reach a lab system from outside the home network, who can use it, and how to close it.
Review when anything network-facing changes. Last reviewed: 2026-10-25.

## From the internet

| Entry point | Lands on | Who can use it | Protected by | Close it |
|---|---|---|---|---|
| Router port forwards (NAT/Gaming) | **None defined** (checked 2026-10-25) | n/a | n/a | n/a |
| Router IP Passthrough | **Off** (checked 2026-10-25) | n/a | n/a | n/a |
| Cloudflare tunnel | Gitea on UbuntuNew (hostnames: _to fill in_) | _To check: anyone, or behind Cloudflare Access?_ | Cloudflare edge; Gitea login | Cloudflare Zero Trust, Tunnels: disable the public hostname, or stop `cloudflared` |
| Router IPv6 (no NAT: every host has a global 2600:1700:... address) | **Blocked**: Reflexive ACL is On (stateful: only replies to outbound connections get in). Checked 2026-10-25 | n/a | Router Firewall Advanced, Reflexive ACL | Keep it On. Packet Filter rules are examples, all disabled |

## From the tailnet (your logged-in devices)

| Entry point | Lands on | Who can use it | Protected by | Close it |
|---|---|---|---|---|
| Tailscale subnet router `gateway` | Lab IPs only (`.83-.96`, `.181`, `.240-.243`), not IoT | `autogroup:member` | `tailscale/policy.hujson` grants; SSH keys on each host | Admin console: remove `homelab-gateway`, or `qm shutdown 121` |
| Tailscale break-glass `tuns` | Hypervisor, tcp 22 and 8006 only | `autogroup:member` | Policy grant; root SSH key-only | Admin console: remove `homelab-breakglass` |

## Address plan

| Range | Use |
|---|---|
| `.83-.96` | Lab VMs (static), see `ansible/inventory/group_vars/all/dns.yml` |
| `.100-.180` | Router DHCP pool (phones, laptops, IoT) |
| `.181` | Proxmox `tuns` (static) |
| `.240-.243` | MetalLB LoadBalancer IPs |
| `.254` | Router |

## Inside the home network (no external path, listed for blast radius)

| Exposure | Why it matters | Planned fix |
|---|---|---|
| Flat LAN: lab shares 192.168.1.0/24 with IoT, phones, TV | A compromised home device can reach Proxmox UI and SSH on every VM | VLAN for the lab (needs router/switch support); Proxmox firewall (week 6) |
| Argo CD (.241), Grafana (.242), Rollouts dashboard (.243) on their own LAN IPs | Admin UIs reachable by any home device, without TLS | Behind ingress with TLS, week 6 |
| VM 100 "LocalAI" (.91), unmanaged local-LLM test VM (also hosted the retired Clawdbot) | Not in inventory, not baselined, missed the 2026-10-24 key revocation | **Shut down 2026-10-25**, `onboot 0`. Delete after 2026-11-01 if nothing missed it |
| Lab static IPs were inside the router DHCP pool (`.64-.253`) | Router could lease `.96` to a phone: gateway and DNS drop off | **Fixed 2026-10-25**: pool is now `.100-.180`, outside `.83-.96`, `.181`, `.240-.243` |

## Open items

- [ ] Cloudflare tunnel: list public hostnames and whether each is behind Access
- [x] Router: DHCP pool moved to `.100-.180`; IPv6 inbound blocked by Reflexive ACL
- [x] VM 100: shut down 2026-10-25
- [ ] VM 100: `qm destroy 100 --purge` after 2026-11-01
- [ ] Optional: router "Drop incoming ICMP Echo requests to LAN" is Off (internet can ping LAN hosts over IPv6). Turning it On hides hosts from ping sweeps
