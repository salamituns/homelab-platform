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
- [x] Worker disks grown via Terraform import ([ADR 0010](docs/adr/0010-adopt-k8s-workers-terraform-import.md), done 2026-10-27: 40 -> 80 GB online, WorkerNode1 70% -> 35%, WorkerNode2 83% -> 41%; plan clean). [ ] Longhorn later, if replicated volumes are still wanted
- [x] ArgoCD "app of apps": MetalLB, ingress, monitoring, rollouts declared in this repo (ADR 0008, adopted 2026-10-27)
- **Proof:** delete the `monitoring` namespace and watch ArgoCD restore it (done 2026-10-27: objects back in ~60 s; Grafana waited for its hand-restored Secret; metrics history lost)

## Week 3: Secure CI pipeline (about two weeks, ADR 0011)
- [x] Rebuild Nexus (+ registry), SonarQube, Jenkins controller + agent with Terraform/Ansible; retire VMs 104-106 (shut down 2026-10-29; **deleted 2026-11-04** after a PBS backup, owner decision)
- [x] Security gates written once in `ci/` scripts; pipelines only call them
- [x] Jenkinsfile for BelleShop: build, test, SonarQube gate, Trivy fs + image scan, SBOM (Syft)
- [x] Push to Nexus only if gates pass; sign images with Cosign (+ SBOM attestation; verified with the public key)
- [x] Gitleaks on every PR in Gitea (Gitea webhook -> Jenkins multibranch, PR-n jobs)
- **Proof:** a PR containing a CVE-laden base image is blocked, with a screenshot of the report.
  Done 2026-10-30: BelleShop PR-3 (`python:3.12.0-slim-bookworm`) blocked by the Image gate, 92 fixable HIGH/CRITICAL
  ([screenshot](docs/evidence/week-03-image-gate-blocked.png))

## Week 4: Supply chain + admission control
- [x] Kyverno: require signed images from Nexus, disallow `:latest`, require resource limits (enforcing 2026-10-31)
- [x] Pod Security Admission `restricted` on app namespaces (enforcing on `dev` 2026-10-31)
- **Proof:** `kubectl run` with an unsigned image is rejected ([evidence](docs/evidence/week-04-admission.txt))

## Week 5: Secrets + identity
- [x] OpenBao on `sectools` ([ADR 0014](docs/adr/0014-secrets-and-identity.md)); External Secrets Operator (done 2026-11-01)
- [x] Move BelleShop MySQL creds out of manifests (the application database password moved, done 2026-11-01;
      the remaining keys are carried over below)
- [x] k8s RBAC: per-namespace dev roles, no cluster-admin kubeconfigs on laptops (done 2026-11-02)
- [x] etcd encryption at rest (done 2026-11-01/02: 34 Secrets rewritten, 34/34 read back encrypted, plaintext count 0 after defrag)
- **Proof:** rotate the DB password in Vault and the app picks it up with no git change —
  done 2026-11-01: 457/457 DB-backed logins during rotation, 0 restarts, no git change

Carried over (kept at the level described in [ADR 0014](docs/adr/0014-secrets-and-identity.md) and its runbooks):
- [x] Alert notifications: Alertmanager routes to null, nothing is delivered yet —
      done 2026-11-03, email receiver via ESO from OpenBao (ADR 0015 step 5)
- [ ] The hand-made `belleshop-secrets` still holds the MySQL root password, user, database name and `SECRET_KEY`;
      only the application database password moved (the shadow `belleshop-secrets-eso` is read by no workload)
- [ ] The unread dead value in `secret/belleshop/app` and the shadow `belleshop-secrets-eso`
- [ ] Old PBS backups keep plaintext Secrets until retention expires (about three months), and values that do not
      rotate stay valid in them
- [ ] MySQL datadir recreation does not recreate the rotation accounts
- [ ] etcd restore is not drilled yet
- [x] NetworkPolicy and NodePorts (Week 6) — done 2026-11-02/03; NodePorts 30080/30081 removed
      (belleshop-deploy #25)
- [ ] Confirm Jenkins holds no copied `admin.conf`

## Week 6: TLS, network and runtime security
- [x] cert-manager with an internal CA, TLS on every `HTTPRoute` (and on the Proxmox UI); move `*.local` hosts to `*.apps.home.arpa`
      (done 2026-11-02; PRs #14-#21, belleshop-deploy #21, BelleShop #16)
- [x] NetworkPolicies: default-deny per namespace (done 2026-11-02/03: kube-network-policies v1.1.2 +
      agent-down alert, default-deny in `dev` and in gateway/monitoring/rollouts/argocd, webhook namespaces
      last; PRs #22-#32, belleshop-deploy #22-#24)
- [x] Proxmox firewall: `tuns` 22/8006 only from the Mac and `tailscale0`, not from every VM (ADR 0003 gap)
      (done 2026-11-03, input DROP; PRs #35, #37-#39; iDRAC recovery path live on shared LOM1
      at 192.168.1.182; negative proof from sectools re-run 2026-11-03)
- [x] Falco for runtime detection, alerts to Alertmanager (done 2026-11-03; PRs #33, #34, #36;
      email receiver via ESO from OpenBao, break-glass root generation restored)
- **Proof:** `kubectl exec` into a pod and spawn a shell, then show the Falco alert —
      `scripts/falco-proof.sh` (ADR 0015 step 5). Cluster side verified live 2026-11-03: 3 Falco
      agents and falcosidekick Running, the rendered Alertmanager config and its falco route
      validated with `amtool` against the live Alertmanager v0.33.1; end to end demoed 2026-11-03:
      the owner ran `scripts/falco-proof.sh` and the Falco alert email arrived
      (`docs/runbooks/falco-alerts.md` §5).
      Netpol proof: `scripts/netpol-proof.sh` (real denied connection, PR #29 hardened it).
      Firewall proof: from sectools, `curl -qk -m 5 https://192.168.1.181:8006/` -> `000` and
      `ssh root@192.168.1.181` times out, while the Mac and Tailscale paths still work.
      Full record with PR numbers and evidence: [ADR 0015 section G](docs/adr/0015-network-policy-and-platform-hardening.md).

Incident during the week: enabling pve-firewall reactivated legacy 10.2.x NAT rules and cut
HTTP(S) to lab services for about 40 minutes
([postmortem](docs/postmortems/2026-11-03-pve-firewall-legacy-nat-outage.md), fixed by PR #39).

Carried over from Week 6 (kept at the level described in [ADR 0015](docs/adr/0015-network-policy-and-platform-hardening.md) section G and its runbooks):
- [x] OIDC/SSO for the admin UIs moved into Week 7 as the designed first item ([ADR 0016](docs/adr/0016-oidc-sso-admin-uis-gitea.md); design only, rollout pending)
- [ ] Remove the stale dnsmasq on `tuns` (legacy `homelab.local` config listening on 10.2.6.181,
      superseded by ADR 0004, now also cut off by the host firewall): `scripts/pve-dnsmasq-retire.sh`,
      owner-run with `--dry-run`
- [ ] Renew the Proxmox UI certificate by **2028-11-02** (825-day leaf; `docs/runbooks/proxmox-ui-cert.md`)
- [ ] iDRAC, without racadm: set the IP range filter to the Mac (`192.168.1.121/32`) in the web UI,
      and check the licence level (Virtual Console needs Enterprise; Serial over LAN is already enabled)
- [ ] Consider `firewall=1` plus explicit guest rules for the Kubernetes node VMs (their NICs are
      unfiltered today; the datacenter firewall governs host rules only)
- [ ] MySQL TLS for the `mysql-bao` path (ADR 0014 step 6 follow-up; out of ADR 0015 scope because
      it needs MySQL configuration and a restart)
- [ ] Watch for the kube-network-policies release carrying PR #420 (denied-probe-tail noise,
      ADR 0015 section A)

## Week 7: Observability + SLOs
- [x] OIDC SSO for the admin UIs with Gitea as the provider ([ADR 0016](docs/adr/0016-oidc-sso-admin-uis-gitea.md)):
      Grafana `generic_oauth`, Argo CD native OIDC + RBAC groups, oauth2-proxy in front of the Prometheus and
      Alertmanager UIs; rollout order Grafana -> Argo CD -> oauth2-proxy, each step reversible
      - [x] Grafana via Gitea, Admin from `homelab:platform-admins` (2026-11-04, PRs #45-#48: live login found
            root_url, CA subPath mount and `groups_attribute_path` bugs)
      - [x] Argo CD via Gitea, owner-applied `scripts/argocd-oidc-apply.sh` (2026-11-04, PR #49; needed a
            `rollout restart` so the session manager trusts the Gitea root, now in the script)
      - [x] oauth2-proxy for the Prometheus and Alertmanager UIs (2026-11-04, PRs #51-#53; Alertmanager admin-team only,
            gateway can no longer reach :9090/:9093 directly)
      - [x] Separate bot account for agent pushes: `homelab-bot` (2026-11-04, PR #55; Argo CD read token #60)
- [x] Loki for logs, Grafana dashboards as code (2026-11-04, PRs #58, #60, #61; [ADR 0017](docs/adr/0017-logs-dashboards-belleshop-slos.md)):
      grafana/loki SingleBinary on `local-path` (worker PVC, 10Gi, 7d) + Grafana Alloy DaemonSet (Promtail is EOL);
      dashboards as JSON ConfigMaps through the existing kube-prometheus-stack sidecar (`grafana_dashboard=1`)
- [x] SLOs for BelleShop (availability, p95 latency) and alerts on burn rate (2026-11-05, PRs #62, #63; [ADR 0017](docs/adr/0017-logs-dashboards-belleshop-slos.md)):
      blackbox_exporter Probe CRs through the Gateway, hand-written multi-window burn PrometheusRules, email via
      the existing Alertmanager route with Week 6 grouping/`repeat_interval` constraints
- **Proof (done 2026-11-05):** drill via git, belleshop-deploy #26 (backend `replicas: 0`) then #27 (restore).
      Merge 00:26:08Z -> Argo synced 00:28:53Z -> probe failing 00:29:18Z -> Medium-burn email ~00:30Z,
      Fast-burn email 00:32:13Z (6 min merge-to-page) -> restore merged 00:35:00Z -> API back 00:35:53Z
      (53 s) -> Fast-burn resolved email. Timeline in `docs/runbooks/belleshop-slo.md`

## Week 8: Chaos + postmortems
- [ ] Five incidents on purpose: node loss, disk full, bad deploy (Rollouts abort),
      expired cert, leaked secret (detect, revoke, rotate). Design:
      [ADR 0018](docs/adr/0018-week8-chaos-drills.md) (Proposed). Run in that ADR's
      safest-first order; owner-present for disk-full and node-loss (`qm shutdown 107`
      only). Do not run until the listed pre-drill alert PRs exist.
- [ ] One postmortem per incident in `docs/postmortems/` from
      [TEMPLATE.md](docs/postmortems/TEMPLATE.md) (detect / mitigate / recover)
- **Proof:** five postmortems. This is what senior interviews ask about.
