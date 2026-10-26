# Entry points into the lab

Every way to reach a lab system from outside the home network, who can use it, and how to close it.
Review when anything network-facing changes. Last reviewed: 2026-10-26.

## From the internet

| Entry point | Lands on | Who can use it | Protected by | Close it |
|---|---|---|---|---|
| Router port forwards (NAT/Gaming) | **None defined** (checked 2026-10-25) | n/a | n/a | n/a |
| Router IP Passthrough | **Off** (checked 2026-10-25) | n/a | n/a | n/a |
| Cloudflare tunnel (on UbuntuNew) | **Off since 2026-10-25** ([postmortem](postmortems/2026-10-25-gitea-rce-cve-2026-60004.md)). Was: 2 Gitea hostnames, 2 Jenkins hostnames (one to a dead 10.2.0.x origin), **no Cloudflare Access** | Was: anyone | Was: nothing in front | **Tunnel deleted 2026-10-26** (its credential was on UbuntuNew). No host runs `cloudflared` (checked all running VMs) |
| Router IPv6 (no NAT: every host has a global 2600:1700:... address) | **Blocked**: Reflexive ACL is On (stateful: only replies to outbound connections get in). Checked 2026-10-25 | n/a | Router Firewall Advanced, Reflexive ACL | Keep it On. Packet Filter rules are examples, all disabled |

## From the tailnet (your logged-in devices)

| Entry point | Lands on | Who can use it | Protected by | Close it |
|---|---|---|---|---|
| Tailscale subnet router `gateway` | Lab IPs only (`.83-.96`, `.181`, `.240-.243`), not IoT | `autogroup:member` | `tailscale/policy.hujson` grants; SSH keys on each host | Admin console: remove `homelab-gateway`, or `qm shutdown 121` |
| Tailscale break-glass `tuns` | Hypervisor, tcp 22 and 8006 only | `autogroup:member` | Policy grant; root SSH key-only | Admin console: remove `homelab-breakglass` |

## Address plan

| Range | Use |
|---|---|
| `.83-.97` | Lab VMs (static), see `ansible/inventory/group_vars/all/dns.yml` |
| `.121` | The Mac (router fixed allocation; allowed to Gitea by ufw) |
| `.100-.180` | Router DHCP pool (phones, laptops, IoT) |
| `.181` | Proxmox `tuns` (static) |
| `.240-.243` | MetalLB LoadBalancer IPs |
| `.254` | Router |

## Inside the home network (no external path, listed for blast radius)

| Exposure | Why it matters | Planned fix |
|---|---|---|
| Gitea `https://gitea.home.arpa` on `gitea` (`.97`, VMID 122) | Holds platform and app git repositories | **Rebuilt 2026-10-26** ([ADR 0005](adr/0005-gitea-rebuild.md)): Caddy TLS on `443/tcp` allowed by ufw only from `master` (`.90`), `workernode1` (`.89`), `workernode2` (`.84`), `gateway` (`.96`), and Mac (`.121`); Gitea itself on `127.0.0.1:3000`; Gitea SSH off; replaced by lab CA in week 6 |
| `UbuntuNew` (`.83`, VMID 101), retired Gitea host | Ran attacker-supplied code on 2026-10-25 ([postmortem](postmortems/2026-10-25-gitea-rce-cve-2026-60004.md)) | Shut down (`onboot 0`), retained for forensic snapshot until **2026-11-25**, then delete |
| Flat LAN: lab shares 192.168.1.0/24 with IoT, phones, TV | A compromised home device can reach Proxmox UI and SSH on every VM | VLAN for the lab (needs router/switch support); Proxmox firewall (week 6) |
| Argo CD (.241), Grafana (.242), Rollouts dashboard (.243) on their own LAN IPs | Admin UIs reachable by any home device, without TLS | Behind ingress with TLS, week 6 |
| VM 100 "LocalAI" (.91), unmanaged local-LLM test VM (also hosted the retired Clawdbot) | Not in inventory, not baselined, missed the 2026-10-24 key revocation | **Shut down 2026-10-25**, `onboot 0`. Delete after 2026-11-01 if nothing missed it |
| SonarQube (`.86:9000`), Nexus (`.87:8081-8085`), Jenkins (`.88:8080`) | CI services: Sonar admin and Nexus artifacts; Jenkins runs code | **Restricted 2026-10-26** (`playbooks/cicd-firewall.yml`): Sonar and Nexus publish through Docker, which bypasses ufw, so the allowlist is in the `DOCKER-USER` chain (Mac, `gateway`, Jenkins); Jenkins `8080` in ufw (Mac, `gateway`, `gitea`). Legacy `10.2.0.0/21` and dead `8177`/`8502` rules removed. Verified: refused from `sectools` |
| Lab static IPs were inside the router DHCP pool (`.64-.253`) | Router could lease `.96` to a phone: gateway and DNS drop off | **Fixed 2026-10-25**: pool is now `.100-.180`, outside `.83-.97`, `.181`, `.240-.243` |

## Open items

- [x] Cloudflare tunnel: listed; it exposed Gitea (exploited) and Jenkins with no gate; now off
- [x] Cloudflare Zero Trust: tunnel deleted 2026-10-26 (public hostnames go with it); remove leftover DNS CNAMEs to `cfargotunnel.com`
- [x] Legacy VMs (k8s nodes, SonarQube, Jenkins, Nexus, Tomcat) were on DHCP and drifted: static since 2026-10-26 ([postmortem](postmortems/2026-10-26-dhcp-drift-k8s-outage.md))
- [x] SonarQube, Jenkins, Nexus: service ports to named clients only, legacy `10.2.0.0/21` rule removed (2026-10-26). Docker-published ports are filtered in `DOCKER-USER`, not ufw
- [x] Router: DHCP pool moved to `.100-.180`; IPv6 inbound blocked by Reflexive ACL
- [x] VM 100: shut down 2026-10-25
- [ ] VM 100: `qm destroy 100 --purge` after 2026-11-01
- [ ] Optional: router "Drop incoming ICMP Echo requests to LAN" is Off (internet can ping LAN hosts over IPv6). Turning it On hides hosts from ping sweeps
