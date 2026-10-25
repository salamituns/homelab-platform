# ADR 0004: Internal DNS with dnsmasq on `gateway`, zone `home.arpa`

- Status: Accepted
- Date: 2026-10-25

## Context

Everything is addressed by IP (`192.168.1.90`, `192.168.1.181:8006`). IPs change, are easy to
mistype, and certificates (week 6) need names. A legacy `internal_dns` role existed but pointed
clients at a server on a subnet that no longer exists (`10.20.77.181`), made that server the
**primary resolver for all lookups** (one outage breaks all DNS), and used `homelab.local`.

## Decision

| Question | Choice | Why |
|---|---|---|
| Zone name | `home.arpa` | Reserved for home networks (RFC 8375). `.local` belongs to mDNS (clashes on macOS); invented TLDs like `.lab` can become real; a public domain would put the domain in this public repo |
| Server | dnsmasq on `gateway` (192.168.1.96) | Already the network box and reachable over Tailscale; small and simple. Not on the hypervisor (keep it minimal) and not in Kubernetes (the cluster would depend on itself to boot) |
| Records | One list in `ansible/inventory/group_vars/all/dns.yml` | Single source of truth in git; reviewed like code |
| Ingress | Wildcard `*.apps.home.arpa` to the ingress LoadBalancer (192.168.1.240) | New apps need an Ingress, not a DNS change |
| VM clients | systemd-resolved **routing-only** domain `~home.arpa` | Only internal names go to the gateway; internet lookups are untouched, so a gateway outage only breaks internal names |
| Laptop | Tailscale split DNS: `home.arpa` to 192.168.1.96 | Same names at home and away, no change to the router |
| Exposure | dnsmasq listens on 192.168.1.96 only, never forwards plain names or private reverse lookups | Not an open resolver; nothing on the internet can reach it (no port forward) |

## Consequences

- The gateway is now also a dependency for internal names. Break-glass (ADR 0003) does not
  need DNS: use IPs there.
- Records are hand-maintained. A host that changes IP needs a one-line change in `dns.yml`.
  Later: generate records from Terraform outputs.
- Existing Ingresses use `*.local` names (argocd.local, grafana.local). They move to
  `*.apps.home.arpa` with cert-manager in week 6.
- No DNSSEC or DNS-over-TLS inside the lab. Accepted for a LAN-only zone.
