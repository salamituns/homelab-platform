# Entry points into the lab

Every way to reach a lab system from outside the home network, who can use it, and how to close it.
Review when anything network-facing changes. Last reviewed: 2026-10-25.

## From the internet

| Entry point | Lands on | Who can use it | Protected by | Close it |
|---|---|---|---|---|
| Router port forwards (NAT/Gaming) | **None defined** (checked 2026-10-25) | n/a | n/a | n/a |
| Router IP Passthrough | **Off** (checked 2026-10-25) | n/a | n/a | n/a |
| Cloudflare tunnel | Gitea on UbuntuNew (hostnames: _to fill in_) | _To check: anyone, or behind Cloudflare Access?_ | Cloudflare edge; Gitea login | Cloudflare Zero Trust, Tunnels: disable the public hostname, or stop `cloudflared` |
| Router IPv6 firewall | _To check_: hosts get global IPv6 (2600:1700:...) | _To check_ | Router "Firewall Advanced" / Packet Filter | Router: block unsolicited inbound IPv6 |

## From the tailnet (your logged-in devices)

| Entry point | Lands on | Who can use it | Protected by | Close it |
|---|---|---|---|---|
| Tailscale subnet router `gateway` | Lab IPs only (`.83-.96`, `.181`, `.240-.243`), not IoT | `autogroup:member` | `tailscale/policy.hujson` grants; SSH keys on each host | Admin console: remove `homelab-gateway`, or `qm shutdown 121` |
| Tailscale break-glass `tuns` | Hypervisor, tcp 22 and 8006 only | `autogroup:member` | Policy grant; root SSH key-only | Admin console: remove `homelab-breakglass` |

## Inside the home network (no external path, listed for blast radius)

| Exposure | Why it matters | Planned fix |
|---|---|---|
| Flat LAN: lab shares 192.168.1.0/24 with IoT, phones, TV | A compromised home device can reach Proxmox UI and SSH on every VM | VLAN for the lab (needs router/switch support); Proxmox firewall (week 6) |
| Argo CD (.241), Grafana (.242), Rollouts dashboard (.243) on their own LAN IPs | Admin UIs reachable by any home device, without TLS | Behind ingress with TLS, week 6 |
| VM 100 "LocalAI" (.91), unmanaged | Not in inventory, not baselined, missed the 2026-10-24 key revocation | Owner reports the bot was retired: shut down, then delete |
| Static lab IPs likely inside the router DHCP pool | Router could lease `.96` to a phone: gateway and DNS drop off | _To check_: Home Network, Subnets & DHCP; shrink pool below `.83` |

## Open items

- [ ] Cloudflare tunnel: list public hostnames and whether each is behind Access
- [ ] Router: DHCP pool range; IPv6 inbound policy
- [ ] VM 100: shut down, then delete
