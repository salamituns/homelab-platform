# ADR 0015: NetworkPolicy enforcement and platform hardening

- Status: Proposed (owner decision pending).
- Date: 2026-11-02

## Context

Week 6 of the [ROADMAP](../../ROADMAP.md) asks for four hardening gaps to close at once: NetworkPolicies that are
actually enforced, internal CA + TLS on every HTTPRoute and the Proxmox UI (hosts moving from `*.local` to
`*.apps.home.arpa`), the Proxmox firewall, and Falco alerting to Alertmanager. The proof is a `kubectl exec` into a pod
that spawns a Falco alert, plus a real denied connection, because an accepted-but-ignored NetworkPolicy proves nothing.

What we verified on 2026-11-02 (live with the `olatunde` kubeconfig unless noted):

| Area | Current state | Why it matters |
|---|---|---|
| CNI | `kube-flannel-ds` v0.28.9, 3/3 pods. No policy controller anywhere | Flannel does not enforce NetworkPolicy (its README says so; upstream verified). Any policy applied today is silently ignored |
| Gateway | `homelab-gateway` (NGINX Gateway Fabric, MetalLB .240), one HTTP :80 listener, allowedRoutes by the `homelab.arpa/gateway-routes: "true"` namespace label (argo-rollouts, argocd, dev, monitoring) | No HTTPS listener; all six HTTPRoutes are plaintext |
| Routes | argocd-server, grafana, argo-rollouts-dashboard, belleshop-frontend, belleshop-api, belleshop-api-host. All backendRefs are same-namespace | A host rename touches every consumer of `*.local` |
| NodePorts | `dev/backend` 30081, `dev/frontend` 30080 (live objects; zero references in this repo, `rg 30080\|30081` is empty) | Carried over from Week 5; `scripts/route-smoke.sh` goes through .240 hostnames, not the NodePorts |
| TLS today | Caddy `tls internal` per VM host: five separate roots (gitea, nexus, sonarqube, jenkins, sectools) in `ansible/files/ca/`, distributed by the `lab_ca_trust` role. `bao.home.arpa` is issued by the sectools Caddy root. Argo CD embeds the Gitea root in a ConfigMap; Terraform uses the sectools root as its S3 CA bundle | Five CAs with no rotation story; the cluster itself has none |
| Proxmox UI | Default self-signed pveproxy certificate; no pveproxy cert config in the repo | Every browser visit trains the owner to click through a warning |
| Proxmox firewall | Off cluster-wide (comment in `terraform/proxmox/k8s_nodes.tf`). VMs have per-host UFW; `tuns` (.181) accepts 22/8006 from the flat LAN | A compromised home device can reach the hypervisor (noted in `docs/entry-points.md`) |
| Alerting | Alertmanager routes everything to the `null` receiver (comment in `k8s/platform/monitoring/manifests/eso-prometheusrule.yaml`) | The Week 5 carried-over gap: Falco alerts need a receiver to mean anything |
| Admission | Kyverno policies match namespaces labeled `homelab.arpa/admission: enforced`; only `dev` has it. `dev` is also the only PSA restricted namespace (kube-flannel, metallb-system are privileged) | New platform components in their own namespaces are admitted without weakening anything |
| Nodes | 3x Ubuntu 24.04.3, kernel 6.8.0-147-generic, Kubernetes 1.33.13, containerd 2.2.1 | Constrains the policy-controller and Falco driver choices |

## A. NetworkPolicy enforcement (the main decision)

Flannel is confirmed as the running CNI with no policy controller, and the flannel README states that `flanneld` does
not natively enforce NetworkPolicy. Options compared (upstream, verified 2026-11-02):

| Option | Kubernetes 1.33 | Disruption and rollback | Resource cost | Drop observability |
|---|---|---|---|---|
| **kube-network-policies v1.1.2** (kubernetes-sigs, chosen) | No published version matrix (unverified); it is the SIG-Network reference implementation tracking current k/k, actively developed, and it is the option flannel itself ships (`netpol.enabled` in its chart, pinned to image v1.0.0 there) | One DaemonSet added; flannel data plane untouched. Selective capture: packets are only intercepted for pods that a policy targets, so installing it changes nothing until policies exist. Rollback: delete the DaemonSet | One userspace agent per node; traffic of untargeted pods is untouched | Structured JSON verdict logs (allow and deny) at the default verbosity, one line per verdict, no per-packet spam |
| Canal (Calico-for-flannel) v3.33.0 | Calico 3.33 is tested against 1.35/1.36/1.37 only; 1.33 is not actively tested | `canal.yaml` **replaces** the kube-flannel DaemonSet with a combined Calico+flannel agent: a rolling data-plane restart on every node, twice if you roll back by re-applying the flannel manifest | Heavier (calico-node per node, privileged) | Mature drop logging, well documented |
| Cilium 1.20.4 | e2e-tested on 1.33 through 1.36 | Full CNI migration: new overlay, every pod recreated. The old flannel-chaining docs page is gone (404), so chaining is unverified as still supported | Heaviest | Best in class (Hubble) but the most to operate |

**Decision: kube-network-policies v1.1.2**, vendored as a manifest in `k8s/platform/kube-network-policies/` and
deployed by Argo CD into its own namespace. It is the only option that adds real enforcement without touching the
data plane, it logs every verdict (so drops are observable without Hubble), and undo is one deletion. The userspace
enforcement cost only applies to pods a policy actually targets, which on this cluster is the point.

### Flows a default-deny must allow (from live objects)

Before any default-deny, the allow policies below are applied first; they are inert until a deny exists.

| Namespace | Allow | Notes |
|---|---|---|
| `dev` | pod-to-pod: backend and backend-canary to mysql:3306; nginx-gateway pods to backend:8000, backend-canary, frontend:3000; all pods to coredns:53 UDP+TCP | The `mysql-bao` path is special: kube-proxy masquerades LoadBalancer traffic so mysql sees the receiving node in `10.244.0.0/16`, never the sectools source IP (ADR 0014 step 6). Pod-identity allowlists cannot express that path; allow 3306 from the three nodes pod-subnet addresses or leave mysql ingress open until the Bao rotation is tested under deny |
| `nginx-gateway` | ingress on :80 from `192.168.1.0/24` (LAN clients, MetalLB L2 preserves the client IP); egress to backend/frontend (dev), grafana (monitoring), argocd-server (argocd), argo-rollouts-dashboard (argo-rollouts) | The Gateway pods are the only cross-namespace egress point for HTTP |
| `kyverno` | ingress 9443 from `192.168.1.90/32` | API-server-to-webhook traffic arrives from the node IP, not a pod IP. Get this wrong and every create/update is rejected cluster-wide |
| `external-secrets` | egress 443 to `192.168.1.0/24` (bao.home.arpa on sectools); ingress 9443 from `192.168.1.90/32` (webhook) | |
| `argocd` | egress 443 to `192.168.1.0/24` (gitea.home.arpa) and to the API server `.90:6443`; egress to pod targets for health checks | Argo CD deploys everything, so its egress must be verified last and generously |
| `argo-rollouts` | ingress 3100 from nginx-gateway pods (dashboard); egress 6443 to the API server | |
| `monitoring` | Prometheus egress to `10.244.0.0/16` (pod targets), to node IPs :10250 (kubelets), `.90:6443`; ingress to grafana from nginx-gateway pods | |
| `kube-system` | coredns ingress :53 from `10.244.0.0/16` | **Never default-deny kube-system**: etcd and apiserver are hostNetwork static pods, and metrics-server scrapes kubelets. Only the coredns allow goes here |

HostNetwork pods are outside policy scope: kube-flannel, kube-proxy, the MetalLB speaker on master, and the apiserver
and etcd static pods. This is why the webhook allow must be by node IP.

### Rollout order (each step reversible)

1. Deploy the DaemonSet (no policies exist: zero behavior change). Watch agents go ready on all three nodes.
2. Apply the allow policies above (inert).
3. Default-deny `dev` first (test workload), and prove the deny below.
4. Default-deny nginx-gateway, monitoring, argo-rollouts, external-secrets, argocd one at a time; after kyverno and
   external-secrets, the owner (not the limited cert) runs a dummy create to prove admission and ESO still work.
5. Remove `backend` NodePort 30081 and `frontend` NodePort 30080 (dev Services). Verified: no reference in this repo;
   `scripts/route-smoke.sh` and the docs use hostnames on .240. Unverified: the belleshop-deploy repo owns those
   Service manifests, and its CI was not checked from here (no access; the owner should grep it before the PR).

DNS lockout is avoided because the coredns allow is in place before any deny, and kube-system is never denied. Webhook
lockout is avoided because node-IP allows land before any deny in kyverno/external-secrets namespaces, and those two
namespaces are denied last, after an owner-run admission test.

### Proof

A real denied connection: with default-deny on `dev`, `kubectl exec` into a backend pod and `curl mysql:3306` times
out (before this ADR it connects), while the kube-network-policies agent log shows a deny verdict with both endpoints.
Then a single allow policy for the curl target makes it connect again. An accepted-but-ignored policy would pass the
second half and fail the first; only the timeout plus the verdict line proves enforcement.

## B. Internal CA and TLS

### What issues certificates today

Caddy on each VM host, `tls internal` per host (`ansible/roles/caddy/templates/Caddyfile.j2`), so `bao.home.arpa` is
issued by the sectools Caddy root. Five roots exist and are trusted where distributed by `lab_ca_trust`; consumers
embed them one at a time (Argo CD ConfigMap, Terraform `custom_ca_bundle`). There is no rotation process and the
cluster itself (Gateway, MySQL, Proxmox UI) has no CA at all.

### Options

| Option | For | Against |
|---|---|---|
| **cert-manager with an offline root imported as a `ca` ClusterIssuer** (chosen) | One CA for the whole lab; root key never lives on the cluster (custody like the OpenBao unseal shares); leafs renew automatically; etcd is encrypted at rest (ADR 0014 step 8) so the issuer Secret is not plaintext anywhere | The owner generates and stores the root by hand, once |
| cert-manager self-signed (`selfSigned`) ClusterIssuer | Zero manual steps; key lives in-cluster | Root key material sits in etcd and in every etcd snapshot, with no offline custody |
| Offline root + intermediate in cert-manager | Matches production practice; can revoke the intermediate | Two tiers to operate for a handful of leafs; no benefit until multiple intermediates exist |
| OpenBao PKI via the Vault issuer | Uses the store from Week 5 | OpenBao is manual-unseal: after any restart or unseal delay, ALL leaf renewals stop until someone unseals. Wrong failure domain for the lab CA |

**Decision: cert-manager (release 1.21; supports Kubernetes 1.33-1.36, verified upstream) with an offline root.** The
owner generates an ECDSA P-256 root with a 10-year life once, the same custody rules as the OpenBao unseal shares;
the root certificate (public) is vendored at `ansible/files/ca/lab-root.crt` for the `lab_ca_trust` role, and the
key+cert pair is imported as a `ca` ClusterIssuer Secret. Backup is the owner custody copy; rotation is re-import a
new root, let leafs reissue, redistribute the cert, remove the old. The five Caddy roots are not migrated now; moving
VM Caddy hosts to the lab CA is a later, separate step (owner decision 5).

### Gateway API

Add an HTTPS listener on :443 to `homelab-gateway` with `certificateRefs` to a wildcard Certificate `*.apps.home.arpa`
created in `nginx-gateway` (same namespace as the Gateway, so no ReferenceGrant is needed; the cross-namespace Routes
already attach through the allowedRoutes label). A wildcard is chosen over per-host certs: one object, and future host
additions need no new Certificate. The HTTP :80 listener stays; HTTPRoutes get a `RequestRedirect` filter to HTTPS.
Unverified: whether NGINX Gateway Fabric v2.8.0 implements RequestRedirect; check during implementation, and if it
does not, keep both listeners and move the redirect to a follow-up.

DNS needs no change: the wildcard `apps.home.arpa` to .240 already exists
(`ansible/inventory/group_vars/all/dns.yml`, ADR 0004).

### The six routes and what breaks on `*.local` to `*.apps.home.arpa`

| Route | Breaks | Fix |
|---|---|---|
| belleshop-frontend + belleshop-api + belleshop-api-host | The frontend API base URL and its CORS allowlist are in the belleshop-deploy repo (unverified from here) | Change the URL and CORS origin there, same PR as the route rename |
| argocd-server | Cookies are host-scoped (re-login once); Argo CD TLS/insecure mode lives in its Helm values, not in this repo (unverified) | Rename host, verify login loop, adjust values only if the redirect breaks |
| grafana | `root_url` in the kube-prometheus-stack values (not in this repo; unverified); cookies re-login | Update values with the same PR |
| argo-rollouts-dashboard | Cookies only | Rename host |
| `scripts/route-smoke.sh` | The `hosts=(...)` array | One-line edit; run before/after and diff, which is its purpose |

### MySQL and the Proxmox UI

- `mysql-bao`: issue a serving Certificate with a real SAN for the MySQL Service so OpenBao drops `tls=skip-verify`
  (ADR 0014 step 6). This is the first in-cluster consumer of the CA.
- Proxmox UI: pveproxy serves `/etc/pve/local/pveproxy-ssl.pem`. Issue a Certificate for the hypervisor host, and have
  the owner place cert+key+chain there and restart pveproxy (host change, owner-applied). Renewal repeats the same
  owner-run step, or a small script on master run by the owner; the limited kubeconfig cannot read Secret values, so
  no agent can automate the export. Default self-signed today, verified live (browser warning) and from the repo (no
  pveproxy config exists in ansible).

## C. Proxmox firewall

Current state, from the repo: firewall off cluster-wide (`terraform/proxmox/k8s_nodes.tf` comment); per-VM UFW is the
only filtering (e.g. `docs/runbooks/backups.md` for PBS); the flat LAN exposure is already documented in
`docs/entry-points.md`; break-glass from Tailscale (`autogroup:member`, 22 and 8006) is granted in
`tailscale/policy.hujson` and documented in `docs/entry-points.md` and ADR 0003.

Verified callers of the Proxmox API and SSH (this repo): Terraform (`bpg/proxmox ~> 0.117`, API on 8006; credentials
come from environment/tfvars not in the repo, so it runs from the Mac or wherever the owner runs terraform), the
Ansible playbooks (`proxmox-ssh.yml`, `breakglass.yml`) over SSH 22 from the Mac, and the PBS backup job on `tuns`
pushing to pbs `.98:8007` outbound (outbound stays default-accept, so it is unaffected). Nothing on sectools, Jenkins
or in-cluster automation targets 22 or 8006 on `tuns` (verified: `rg` over the repo).

Staged plan for the owner (host changes are never agent-applied; the Mac has no console fallback):

1. Confirm console access first: the Proxmox noVNC console from an allowed source, and the physical console path.
   This is the recovery route if a rule cuts the owner off: fix or disable the firewall from the hypervisor console.
2. With the firewall still disabled, enter the rules: accept 22 and 8006 from the Mac (`192.168.1.121`) and from
   `100.64.0.0/10` (tailscale0, the break-glass path); accept established/related; leave outbound default-accept
   (PBS on 8007 must keep working); no accept for the VM subnet (`192.168.1.84-96`) on 22/8006.
3. Enable the firewall with input policy ACCEPT first (rules loaded, nothing denied), verify SSH and the UI still work.
4. Switch input to DROP. Test from each source: Mac SSH and UI pass; tailscale0 (break-glass) passes; the negative
   proof from a VM (sectools): SSH to `.181:22` and `curl https://192.168.1.181:8006` both fail.
5. Same rules, then same stages, for any future Proxmox nodes; today there is one (`tuns`), so no corosync ports.

Undo at every stage: set input policy back to ACCEPT, or disable the firewall from the console.

## D. Falco

- **Driver: modern eBPF probe** (Falco default). Requirements are kernel BTF + ring buffer, present in
  6.8.0-147-generic; no kernel module, no headers, no dkms (verified in the Falco docs). Nothing to build on kernel
  upgrades.
- **Chart: falco 9.2.2** (appVersion Falco 0.45.2, released 2026-10-30; the chart also carries the falcosidekick
  dependency at 0.14.x). Pin the chart and image digests when vendoring. Resource cost: one DaemonSet pod per node;
  set explicit requests/limits at install (the chart defaults are unverified here) and check node headroom.
- **Privileges:** the modern eBPF probe can run least-privileged with `CAP_SYS_BPF`, `CAP_SYS_PERFMON`,
  `CAP_SYS_RESOURCE`, `CAP_SYS_PTRACE` (kernel 5.8+). Falco runs in a new `falco` namespace with the PSA
  `privileged` label (like kube-flannel and metallb-system), which the admission setup permits without weakening
  anything (section E).
- **Delivery to Alertmanager:** falcosidekick (in the same chart) forwards to the existing Alertmanager service in
  `monitoring`. Alertmanager currently routes everything to the `null` receiver (verified in
  `k8s/platform/monitoring/manifests/eso-prometheusrule.yaml`), so this needs a real receiver to mean anything, and it
  closes the Week 5 carried-over alert gap. Recommended receiver: SMTP to the owner with credentials stored in OpenBao
  and pulled by ESO into `monitoring` (the SecretStore pattern from ADR 0014 already exists there); if the owner
  prefers no external account, the fallback is a webhook receiver on an existing service. Owner decision 3.
- **Noise:** the proof rule (`Terminal Shell in Container`, Warning) must stay on. `kubectl exec` by
  `belleshop-operators` into `dev` pods and the scripted execs of `scripts/openbao-setup-mysql-rotation.sh` will fire
  it by design; tune by raising the priority threshold of other rules (contact API server, package managers) or
  adding conditions on the noisy-but-benign sources, never by dropping the exec/shell rule or routing Falco alerts
  below the receiver threshold.

**Proof:** `kubectl exec` into a `dev` pod, spawn a shell, and the Falco event appears in the Alertmanager receiver
end to end (Falco log line, falcosidekick forward, Alertmanager notification).

## E. Admission (Week 4 Kyverno)

Verified live: the image-verification and registry-restriction policies match namespaces labeled
`homelab.arpa/admission: enforced`, and only `dev` carries it. So cert-manager, Falco, kube-network-policies and any
CNI images are admitted in their own namespaces without weakening BelleShop policy. Nothing needs to change. If a
platform component ever must run inside `dev`, it must come from `registry.home.arpa` like the app images; the Nexus
proxy pattern is the answer there, not a policy exception.

## F. Rollout plan

Who does what: agents write manifests and open PRs; Argo CD deploys what is merged; the owner applies host and
privileged changes (the Mac has no cluster-admin, and the `olatunde` kubeconfig cannot read Secrets, list
clusterpolicies or referencegrants, or list services cluster-wide, so it cannot deploy any of these alone).

| # | Step | Reversible by | Who |
|---|---|---|---|
| 0 | Add `cert-manager`, `falco`, `kube-network-policies` to the AppProject destinations list | Revert the PR | Agent (PR), Argo CD (deploy) |
| 1 | B: cert-manager + offline root ClusterIssuer + wildcard Certificate + HTTPS listener; then MySQL SAN cert | Revert the PRs; certs reissue | Owner (root generation, on the Mac), Agent (PRs), Argo CD |
| 2 | B: rename the six hosts, update route-smoke.sh, frontend URL/CORS, Grafana root_url, Argo CD values | Revert PRs; DNS wildcard already covers both names, so rollback is instant | Agent (PRs), Owner (belleshop-deploy PR) |
| 3 | A: kube-network-policies DaemonSet; allow policies; default-deny dev; proof; then the other namespaces one at a time | Delete the DaemonSet (all enforcement stops); delete policies one at a time | Agent (PRs), Argo CD, Owner (admission test) |
| 4 | A: remove NodePorts 30080/30081 after checking belleshop-deploy CI | Revert the Service PR | Agent (PRs), Owner (belleshop-deploy) |
| 5 | D: Falco chart + falcosidekick + Alertmanager receiver + credential in OpenBao | Delete the falco app; receiver route revert | Agent (PRs), Owner (SMTP credential, OpenBao) |
| 6 | C: Proxmox firewall staged on `tuns` (section C) | Input ACCEPT or disable from console | Owner only |

Recommended order and why: B first (pure additions, no traffic impact, and the CA unlocks the MySQL and Proxmox
certs), A second (the core gap; controller alone changes nothing, so the risky part is staged inside it), D third
(independent, needs only the Alertmanager receiver), C last (owner-only, highest lockout risk; do it when nothing
else is mid-flight and attention is on recovery).

Proofs, in order: HTTPS curl with `--cacert ansible/files/ca/lab-root.crt` on all six hosts and the Proxmox UI;
`scripts/route-smoke.sh` diff before/after the rename; the denied-connection proof of section A; the `kubectl exec`
Falco alert of section D; the Proxmox negative test of section C.

## Decisions for the owner

| # | Decision | Recommendation |
|---|---|---|
| 1 | Policy controller: kube-network-policies vs Canal | kube-network-policies v1.1.2 (data plane untouched, verdict logs, one-command rollback) |
| 2 | CA design | cert-manager 1.21 with an offline root imported as the `ca` ClusterIssuer; owner custody like the OpenBao shares |
| 3 | Alertmanager receiver | SMTP with the credential in OpenBao behind ESO; otherwise a webhook on an existing service |
| 4 | Proxmox firewall timing | Last, after A/B/D are stable, with the console recovery path tested first |
| 5 | Move the five Caddy VM roots to the lab CA now or later | Later, separate PR per host; the lab CA proves itself on cluster and Proxmox first |
| 6 | Wildcard `*.apps.home.arpa` vs per-host certs | Wildcard |

## Sources

Checked 2026-11-02:

- [flannel README](https://github.com/flannel-io/flannel) — `flanneld` does not natively enforce Network Policies; the README lists kube-network-policies, Calico-for-flannel (Canal) and Cilium as the add-on options. [flannel chart values](https://github.com/flannel-io/flannel/blob/master/chart/kube-flannel/values.yaml) — `netpol.enabled` deploys `registry.k8s.io/networking/kube-network-policies` (chart pins image v1.0.0); latest flannel release v0.28.10, this cluster runs v0.28.9
- [kube-network-policies](https://github.com/kubernetes-sigs/kube-network-policies) and its [docs site](https://kube-network-policies.sigs.k8s.io/docs/) — kubernetes-sigs reference implementation, v1.1.2 (2026-09-28), userspace NFQUEUE/nftables enforcer, selective capture, structured JSON verdict logs, ANP/BANP support
- [Calico for policy and flannel (Canal) install](https://docs.tigera.io/calico/latest/getting-started/kubernetes/flannel/install-for-flannel) — `canal.yaml` v3.33.0 replaces the flannel DaemonSet; [system requirements](https://docs.tigera.io/calico/latest/getting-started/kubernetes/requirements) — Calico 3.33 tested only on Kubernetes 1.35-1.37
- [Cilium Kubernetes compatibility](https://docs.cilium.io/en/stable/network/kubernetes/compatibility/) — stable 1.20.4 e2e-tests Kubernetes 1.33-1.36
- [cert-manager supported releases](https://cert-manager.io/docs/releases/) — release 1.21 (2026-07-08), supports and tests Kubernetes 1.33-1.36
- [Falco kernel events/drivers](https://falco.org/docs/concepts/drivers/) — modern eBPF probe is the default; needs BTF and ring buffer support (kernels around 5.8+), no kernel module; least-privileged capabilities list. [falcosecurity charts releases](https://github.com/falcosecurity/charts/releases) — falco chart 9.2.2 (appVersion Falco 0.45.2, 2026-10-30), falcosidekick chart 0.14.x

## What was unverified

To check during implementation, not blocking the decision: kube-network-policies has no published Kubernetes version matrix (1.33
compatibility is inferred from its role as the SIG-Network reference implementation tracking current k/k, and from
flannel shipping it); NGINX Gateway Fabric v2.8.0 support for the RequestRedirect filter; falco chart default
resource requests; where Terraform is run from; belleshop-deploy repo contents (frontend API URL, CORS, CI use of
30080/30081); Argo CD TLS mode and Grafana `root_url` (both live outside this repo). Image digests are pinned at
implementation time, not here.
