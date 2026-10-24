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
- [Credential inventory](docs/credentials.md)
- [ADRs](docs/adr/): architecture decisions
