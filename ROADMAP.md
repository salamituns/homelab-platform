# homelab-platform roadmap: DevSecOps / Platform Engineering

Goal: run the lab like an internal cloud platform. Everything lives in git,
everything is scanned, and anything can be rebuilt.

Each week ends with **proof**: something you can demo or link in an interview.

## Starting point (2026-10-23)
- Proxmox 9.1 on `tuns` (40c / 62G / 3.7T thin LVM), 12 hand-built VMs
- K8s 1.31 (kubeadm, flannel, 1 control + 2 workers) with ArgoCD, Argo Rollouts, MetalLB,
  ingress-nginx, kube-prometheus-stack, local-path storage
- BelleShop deployed by ArgoCD from self-hosted Gitea
- Gaps: no IaC, platform add-ons not in git, no security layer, no metrics-server,
  worker disks at 73% / 81%

## Week 1: Infrastructure as Code + secure baseline
- [x] Proxmox API token for Terraform with a least-privilege role (not root)
- [x] `terraform apply` creates `sectools` (VMID 120) from template 109
- [x] Ansible baseline role: packages, auto security updates, fail2ban, auditd
- [x] SSH hardening tasks (you write these)
- [x] pre-commit: gitleaks, tflint, trivy config scan, ansible-lint
- [x] Baseline applied to UbuntuNew (Gitea) and sectools; legacy sshd Include bug fixed
- [x] **Proof:** `terraform destroy && terraform apply && make baseline` rebuilds a hardened VM (done 2026-10-24)
- [x] Repo on private Gitea, push-mirrored to public GitHub; history scrubbed before first push

## Week 1.5: Remote access + network foundations
Why: on 2026-10-24 the Mac was on a phone hotspot mid-incident and could not reach anything.
See [ADR 0002](docs/adr/0002-remote-access-tailscale-subnet-router.md).
- [x] `gateway` VM (VMID 121, .96) by Terraform, baseline-hardened
- [x] Tailscale subnet router on `gateway`, advertising 192.168.1.0/24, tagged device
- [x] Access policy in git (`tailscale/policy.hujson`): members to LAN only, gateway cannot reach members
- [x] Single-use, tagged, short-lived auth key; documented in `docs/credentials.md`
- [x] Break-glass: Tailscale on `tuns`, no routes, narrow grant ([ADR 0003](docs/adr/0003-break-glass-access.md)); drill passed 2026-10-25 from a hotspot
- [x] Internal DNS: `*.home.arpa` from dnsmasq on `gateway`, split DNS over Tailscale
      ([ADR 0004](docs/adr/0004-internal-dns.md); replaces the legacy `internal_dns` role)
- [x] Inventory of every way into the lab: [docs/entry-points.md](docs/entry-points.md) (open items tracked there)
- **Proof (done 2026-10-24 for access; laptop test in policy):** from a phone hotspot, `ssh Master`, open the Proxmox UI, and `kubectl get nodes` all work,
  and a test in `policy.hujson` shows the gateway cannot connect back to your laptop

## Incident 2026-10-25 follow-ups (before Week 2)
See [postmortem](docs/postmortems/2026-10-25-gitea-rce-cve-2026-60004.md).
- [x] Rebuild Gitea on a Terraform VM with an Ansible role (TLS, pinned version), migrate repos, and cut over (`gitea`, VMID 122, `.97`; done 2026-10-26)
- [x] Shut down `UbuntuNew` (2026-10-26, `onboot 0`); [ ] delete after 2026-11-25
- [x] SonarQube `admin` still had the factory password: changed 2026-10-26
- [x] Re-add the GitHub push mirror with a new fine-grained token (2026-10-26)
- [x] Stop the DockerApp Actions runner (`restart=no`; it still polled the tunnel hostname with the Docker socket mounted); old runners died with UbuntuNew's DB
- [x] Delete the Cloudflare tunnel (revokes its credential, which sat on UbuntuNew) (2026-10-26)
- [x] Legacy VMs on DHCP drifted after the pool change and took the k8s API down: pinned to static addresses with `ansible/roles/static_ip` (2026-10-26, [postmortem](docs/postmortems/2026-10-26-dhcp-drift-k8s-outage.md))
- [x] SonarQube, Jenkins, Nexus: drop the legacy `10.2.0.0/21` ufw rule; open service ports to named clients only (`playbooks/service-firewall.yml`, 2026-10-26)

## Week 2: State, storage and the platform in git
- [x] Backups first (baseline C1, [ADR 0006](docs/adr/0006-backups-proxmox-backup-server.md)): Debian 13 template, PBS VM, daily job for every VM, Gmail alerts, restore drill (done 2026-10-26: first backup 15 VMs / 113 GiB, gitea restore drill PASS in 6 min). [ ] Stage 2 (second medium) deferred
- [x] ~~MinIO~~ SeaweedFS on `sectools` ([ADR 0007](docs/adr/0007-terraform-state-seaweedfs-s3.md); MinIO CE is archived): Terraform state in S3 with native locking, versioning and 30-day Object Lock (done 2026-10-27: lock test refused the second plan with 412; key cannot delete history)
- [x] metrics-server with verified kubelet TLS, no `--kubelet-insecure-tls` ([ADR 0009](docs/adr/0009-metrics-server-verified-kubelet-tls.md), done 2026-10-27: CA-signed kubelet certs on all 3 nodes, `kubectl top` works)
- [ ] Longhorn (or grow worker disks via Terraform import)
- [x] ArgoCD "app of apps": MetalLB, ingress, monitoring, rollouts declared in this repo (ADR 0008, adopted 2026-10-27)
- **Proof:** delete the `monitoring` namespace and watch ArgoCD restore it (done 2026-10-27: objects back in ~60 s; Grafana waited for its hand-restored Secret; metrics history lost)

## Week 3: Secure CI pipeline
- [ ] Jenkinsfile for BelleShop: build, test, SonarQube gate, Trivy fs + image scan, SBOM (Syft)
- [ ] Push to Nexus only if gates pass; sign images with Cosign
- [ ] Gitleaks on every PR in Gitea
- **Proof:** a PR containing a CVE-laden base image is blocked, with a screenshot of the report

## Week 4: Supply chain + admission control
- [ ] Kyverno: require signed images from Nexus, disallow `:latest`, require resource limits
- [ ] Pod Security Admission `restricted` on app namespaces
- **Proof:** `kubectl run` with an unsigned image is rejected

## Week 5: Secrets + identity
- [ ] Vault (or OpenBao) on the cluster; External Secrets Operator
- [ ] Move BelleShop MySQL creds out of manifests
- [ ] k8s RBAC: per-namespace dev roles, no cluster-admin kubeconfigs on laptops
- **Proof:** rotate the DB password in Vault and the app picks it up with no git change

## Week 6: TLS, network and runtime security
- [ ] cert-manager with an internal CA, TLS on every ingress (and on the Proxmox UI); move `*.local` ingress hosts to `*.apps.home.arpa`
- [ ] NetworkPolicies: default-deny per namespace
- [ ] Proxmox firewall: `tuns` 22/8006 only from the Mac and `tailscale0`, not from every VM (ADR 0003 gap)
- [ ] Falco for runtime detection, alerts to Alertmanager
- **Proof:** `kubectl exec` into a pod and spawn a shell, then show the Falco alert

## Week 7: Observability + SLOs
- [ ] Loki for logs, Grafana dashboards as code
- [ ] SLOs for BelleShop (availability, p95 latency) and alerts on burn rate
- **Proof:** a dashboard plus an alert that fired for a real reason

## Week 8: Chaos + postmortems
- [ ] Five incidents on purpose: node loss, disk full, bad deploy (Rollouts abort),
      expired cert, leaked secret (detect, revoke, rotate)
- [ ] One postmortem per incident in `docs/postmortems/`
- **Proof:** five postmortems. This is what senior interviews ask about.
