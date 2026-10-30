# homelab-platform

Infrastructure, configuration and platform code for the home lab, run as an internal cloud platform.

| Layer | Tool | Path |
|---|---|---|
| VMs on Proxmox | Terraform (`bpg/proxmox`) | `terraform/proxmox/` |
| In-guest config | Ansible | `ansible/` |
| K8s platform | ArgoCD (week 2) | `k8s/` |
| Decisions | ADRs | `docs/adr/` |

## Quick start
```sh
cp .envrc.example .envrc            # add the Proxmox API token
cp terraform/proxmox/terraform.tfvars.example terraform/proxmox/terraform.tfvars
source .envrc
pre-commit install
make init plan                      # review the plan
make apply
make baseline-check HOST=sectools   # dry run first, always
make baseline HOST=sectools
```

See [ROADMAP.md](ROADMAP.md) for the 8-week plan.

## Docs
- [Week 1 log](docs/week-01.md): what was built, why, every command, problems hit
- [Runbook: rebuild a VM](docs/runbooks/rebuild-vm.md): destroy and rebuild drill
- [Runbook: enable remote access](docs/runbooks/enable-remote-access.md): Tailscale subnet router
- [Runbook: break-glass access](docs/runbooks/break-glass.md): back door when the gateway is down, with a drill
- [Runbook: internal DNS](docs/runbooks/internal-dns.md): `*.home.arpa` names, split DNS over Tailscale
- [Runbook: Gitea](docs/runbooks/gitea.md): operate, upgrade, trust CA, rotate Argo CD token, restore dump
- [Runbook: CI platform](docs/runbooks/ci-platform.md): Nexus, SonarQube, Jenkins, agent; build order, secrets, failures
- [Runbook: drained node reboot](docs/runbooks/drained-node-reboot.md): one k8s node at a time
- [Architecture](docs/architecture.md): topology, trust boundaries, CI/CD pipeline, supply chain, open gaps
- [Entry points](docs/entry-points.md): every way into the lab and how to close it
- Postmortems: [2026-10-24 hypervisor key](docs/postmortems/2026-10-24-hypervisor-key-exposure.md), [2026-10-25 Gitea RCE](docs/postmortems/2026-10-25-gitea-rce-cve-2026-60004.md), [2026-10-26 DHCP drift](docs/postmortems/2026-10-26-dhcp-drift-k8s-outage.md)
- [Credential inventory](docs/credentials.md)
- [ADRs](docs/adr/): architecture decisions
