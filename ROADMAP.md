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
- **Proof:** `terraform destroy && terraform apply && make baseline` rebuilds a hardened VM

## Week 2: State, storage and the platform in git
- [ ] MinIO on `sectools`, Terraform state moved to an S3 backend with locking
- [ ] metrics-server, Longhorn (or grow worker disks via Terraform import)
- [ ] ArgoCD "app of apps": MetalLB, ingress, monitoring, rollouts declared in this repo
- **Proof:** delete the `monitoring` namespace and watch ArgoCD restore it

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
- [ ] cert-manager with an internal CA, TLS on every ingress (and on the Proxmox UI)
- [ ] NetworkPolicies: default-deny per namespace
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
