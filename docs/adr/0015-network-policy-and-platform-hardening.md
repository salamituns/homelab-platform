# ADR 0015: NetworkPolicy enforcement and platform hardening

- Status: Proposed (owner decision pending).
- Date: 2026-11-01, corrected on this branch after review of the first draft

## Context

Week 6 of the [ROADMAP](../../ROADMAP.md) closes four hardening gaps: NetworkPolicies that are actually enforced,
internal CA + TLS on every HTTPRoute and the Proxmox UI (hosts moving from `*.local` to `*.apps.home.arpa`), the
Proxmox firewall, and Falco alerting to Alertmanager. The proofs: a real denied connection (an accepted-but-ignored
policy proves nothing) and a `kubectl exec` into a pod that spawns a Falco alert.

Verified live with the `olatunde` kubeconfig on 2026-11-01 (the cert can read pods, nodes and namespace labels
cluster-wide; it cannot read Secrets, ConfigMaps in kube-system, Services in most namespaces, or list
clusterpolicies):

| Area | Current state | Why it matters |
|---|---|---|
| CNI | `kube-flannel-ds` v0.28.9, 3/3 pods; no policy controller | Flannel does not enforce NetworkPolicy; policies are silently ignored |
| Gateway | `homelab-gateway` (NGF v2.8.0, MetalLB .240), one HTTP :80 listener; 6 HTTPRoutes, all same-namespace backendRefs | No HTTPS; all routes plaintext |
| NodePorts | `dev/backend` 30081, `dev/frontend` 30080. Defined in `belleshop-deploy/base/{backend,frontend}-service.yaml`; zero references in this repo | Week 5 carry-over |
| TLS today | Caddy `tls internal` per VM host; five separate roots under `ansible/files/ca/` distributed by `lab_ca_trust`. Argo CD embeds the Gitea root; Terraform uses the sectools root | Five CAs, no rotation story, none for the cluster |
| Proxmox UI | Default node certificate (`/etc/pve/nodes/*/pve-ssl.pem`) signed by the PVE cluster CA, "not automatically trusted by browsers" ([PVE docs](https://pve.proxmox.com/wiki/Certificate_Management)) | Not verified from a browser here; stated from the docs and the absence of cert config in the repo |
| Proxmox firewall | Off cluster-wide (`terraform/proxmox/k8s_nodes.tf` comment) | Flat LAN can reach the hypervisor |
| Alerting | Alertmanager routes everything to the `null` receiver (`k8s/platform/monitoring/manifests/eso-prometheusrule.yaml` comment) | Week 5 carried gap |
| Admission | Only `dev` carries `homelab.arpa/admission: enforced` and PSA restricted (live namespace labels) | Platform components in own namespaces are admitted unchanged |
| Nodes | master (.90, podCIDR 10.244.0.0/24), workernode1 (.89, 10.244.3.0/24), workernode2 (.84, 10.244.4.0/24); kernel 6.8.0-147-generic, k8s 1.33.13, kube-proxy iptables mode (recorded in `docs/runbooks/openbao.md`; its ConfigMap is not readable with this cert) | Constrain driver and source-address math |

## A. NetworkPolicy enforcement

Flannel is confirmed as the running CNI with no policy controller, and its README states `flanneld` "does not
natively enforce Network Policies". Options:

| Option | Kubernetes 1.33 | Disruption and rollback | Drop observability | Production track record |
|---|---|---|---|---|
| **kube-network-policies v1.1.2** (kubernetes-sigs, chosen) | No published matrix (unverified). It is the SIG-Network reference implementation tracking current k/k, and the option flannel's own chart ships under `netpol.enabled` (chart pins image v1.0.0) | One DaemonSet; flannel untouched. Selective capture: only pods targeted by a policy are intercepted. **Fail-open by default**: `--fail-open`, default `true` — "If true, do not drop packets if the agent is not running or crashes" ([docs](https://kube-network-policies.sigs.k8s.io/docs/user/flavors-and-architectures/)). Deleting the DaemonSet or a crash therefore does not blackhole traffic; enforcement stops, which is the pre-install state | Structured JSON verdict logs at default verbosity, one line per verdict | No upstream production-readiness statement found (unverified). Known sharp edge: [issue #417](https://github.com/kubernetes-sigs/kube-network-policies/issues/417) — after a node-side close, tail packets of node-to-pod HTTPS probe connections were denied (noise, probes still passed); fixed after v1.1.2 in [PR #420](https://github.com/kubernetes-sigs/kube-network-policies/pull/420), so v1.1.2 carries the noise until the next release |
| Canal (Calico for policy on flannel) v3.31.7 | Calico 3.31 is tested against 1.32-1.35 ([requirements](https://docs.tigera.io/calico/3.31/getting-started/kubernetes/requirements)); 3.33, the current release, tests only 1.35-1.37 | `canal.yaml` replaces the kube-flannel DaemonSet with a combined agent: a rolling data-plane restart on every node, twice on rollback | Mature, documented | Battle-tested; heavier (privileged calico-node per node) |
| Cilium 1.20.4 | e2e-tested 1.33-1.36 ([compatibility](https://docs.cilium.io/en/stable/network/kubernetes/compatibility/)) | Full CNI migration; every pod recreated | Best (Hubble) | Most to operate for one lab |

**Decision: kube-network-policies v1.1.2**, vendored as a manifest and deployed by Argo CD into its own namespace,
keeping the default fail-open (availability over enforcement here; strict-mode also defaults on). Fail-open has a cost:
if the agent is down, every policy silently stops applying, so a PrometheusRule on the DaemonSet's unavailable pods
is part of this step, and its alert must reach the real receiver from section D. The #417 noise is accepted until the fix ships: it adds denial-log entries, not outages. Rollback is deleting the DaemonSet — with
fail-open the packets then simply stop being intercepted. One day-one check: this cluster runs kube-proxy in
iptables mode (Ubuntu 24.04, where iptables is nft-backed) and the agent adds its own nftables NFQUEUE rules; the two
coexist in upstream deployments ([#417](https://github.com/kubernetes-sigs/kube-network-policies/issues/417) reports
it in production on EKS), but no upstream statement promises iptables-mode compatibility specifically — verify with
the denial proof below before the first default-deny.

**Proof (a real denied connection, using tools the images have):** with default-deny on `dev`:
(1) `kubectl -n dev exec <frontend-pod> -- wget -T 3 -O /dev/null http://mysql:3306` — the frontend is
`nginx:alpine` with curl deliberately removed (its Dockerfile), busybox `wget` should remain; verify on day one —
times out or refuses, and the agent log shows the DENY verdict with both endpoints;
(2) `kubectl -n dev exec <backend-pod> -- python3 -c "..."` to `mysql:3306` still connects (the backend is
`python:3.12-slim`), proving the deny is the policy, not the network;
(3) the DB-backed flows still work: `BelleShop/scripts/05-test-belleshop.sh` user registration (step 3) succeeds
through the gateway. An ignored policy would fail (1); a broken rollout would fail (2) or (3).

### Default-deny scope

| Namespace | Denied | Notes |
|---|---|---|
| `dev` | ingress + egress | The workload; egress must allow DNS, mysql, nothing else |
| `nginx-gateway`, `monitoring`, `argocd`, `argo-rollouts` | ingress + egress | Entry point and its consumers |
| `external-secrets`, `kyverno` | ingress + egress, **last** | Webhook lockout risk; owner runs a dummy create after each |
| `cert-manager` (new) | ingress + egress once its webhook allow is proven | Same order rule as kyverno |

Exempt, with reasons: `kube-system` (hostNetwork apiserver/etcd static pods, kube-proxy; a deny here can break the
cluster itself and the node-to-pod exemption below only covers the local node), `kube-flannel` (hostNetwork CNI),
`metallb-system` (speaker is hostNetwork; control plane needs free ARP/API access), `local-path-storage`
(provisioner talks to kubelets during volume operations; not worth the risk), `default` (empty), `falco` (new;
host-level agent, see D). No kube-system allow policy is needed for its own sake: coredns ingress stays open
because kube-system is never denied. The DNS rule that matters is the *egress* allow in each denied namespace
(appendix).

Node-to-pod traffic: connections from a pod's own node are always accepted by this agent (the K8s docs rule it
implements; via a `meta skuid 0` rule, per [#417](https://github.com/kubernetes-sigs/kube-network-policies/issues/417)),
so kubelet probes survive default-deny. Cross-node node traffic is **not** exempt (see appendix: webhooks).

### Rollout order (each step reversible, each step checked)

1. Deploy the DaemonSet (no policies exist: no behavior change). Agents ready on all three nodes.
2. Apply the allow policies (appendix). Inert until a deny exists.
3. Default-deny `dev`; run the proof above. Check: `BelleShop/scripts/05-test-belleshop.sh` passes.
4. Default-deny nginx-gateway, monitoring, argo-rollouts, argocd, one at a time. Check after each: Argo CD shows
   the apps Synced/Healthy (the argocd deny is the risky one — do it while watching a sync).
5. Default-deny external-secrets and kyverno, and add cert-manager, last. Check after each: the owner runs a dummy
   `kubectl apply`, ESO refreshes its secrets, and one **real rotation** under deny (the rotation path is the
   masquerade wrinkle in the appendix).
6. Remove `backend` nodePort 30081 and `frontend` nodePort 30080 (belleshop-deploy Service manifests). Verified:
   nothing in either repo uses them — `BelleShop/scripts/05-test-belleshop.sh` curls `192.168.1.240` with a Host
   header, and `scripts/route-smoke.sh` uses .240 hostnames.

DNS lockout: every denied namespace's egress allow to coredns lands in step 2, before any deny. Webhook lockout:
the node-subnet allows (appendix) land in step 2, and the webhook namespaces are denied last (step 5), after
admission and ESO are re-proven.

## B. Internal CA and TLS

### The CA

Five per-host Caddy roots exist; there is no lab CA. Chosen design — two tiers, and the root really is offline:

1. **Root, offline on the owner's side.** Generated once on the Mac (never on a server):
   `openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout lab-root.key -out lab-root.crt -days 3650`
   with a config that adds a **DNS name constraint to `home.arpa`** (and `home.arpa` only). Why the constraint: a
   root trusted on the Mac could otherwise vouch for any site on the internet; constrained, its worst case is this
   lab. Enforcement by the clients here: OpenSSL enforces DNS name constraints in chain verification since 1.0.0
   ([CHANGES](https://www.openssl.org/news/changelog.html); Python's `ssl` uses OpenSSL); Go has enforced them
   long-term and since 1.19 also on non-leaf certificates
   ([Go 1.19 notes](https://go.dev/doc/go1.19)); macOS since 10.13.3
   ([Apple HT208465](https://support.apple.com/en-us/HT208465), corroborated by the BetterTLS suite — official
   developer documentation of current enforcement is otherwise sparse, unverified). Curl on the Mac uses
   LibreSSL/OpenSSL (enforces); the owner's browser uses the Apple stack (enforces per above).
   Custody: like the OpenBao unseal shares. The root **key never leaves the owner's storage**; the cert is vendored
   at `ansible/files/ca/lab-root.crt` for `lab_ca_trust`. Expiry 10 years; rotation = generate a new root, re-sign
   the intermediate, redistribute the cert — rare by design.
2. **Intermediate, in cert-manager.** The owner signs one intermediate (5 years) with the offline root
   (`openssl x509 -req -CA lab-root.crt -CAkey lab-root.key -extfile ...` adding `pathlen:0` and the same name
   constraint), then imports cert+key as the `ca` ClusterIssuer Secret. cert-manager (release 1.21, supports k8s
   1.33-1.36, [releases](https://cert-manager.io/docs/releases/)) issues 90-day leafs and renews them
   automatically. The intermediate key is on the cluster, in etcd — encrypted at rest since ADR 0014 step 8.
   Intermediate expiry is the one date to remember: 5 years, owner calendar at 4 years. Rotation: sign a new
   intermediate from the same root, import, leafs reissue, no client changes (root trust is unchanged).

The first draft put the root key itself in the cluster and called it offline; that was a one-tier design with a
manual step. OpenBao PKI stays rejected: OpenBao is manual-unseal, and a sealed store would stall every renewal.

### Gateway API

- HTTPS listener on :443 on `homelab-gateway`, `certificateRefs` to a wildcard Certificate for `*.apps.home.arpa`
  in `nginx-gateway` (same namespace as the Gateway, so no ReferenceGrant; routes already attach via the
  allowedRoutes label). One wildcard beats per-host: one object, no per-host Certificate.
- `*.apps.home.arpa` matches exactly one label. All new hosts are single-label; the two-label API host is renamed
  accordingly (table below).
- HTTP→HTTPS: NGF 2.8.0 supports the `requestRedirect` filter — "Supported. If multiple filters are configured,
  NGINX Gateway Fabric will choose the first and ignore the rest" ([Gateway API compatibility](https://docs.nginx.com/nginx-gateway-fabric/overview/gateway-api-compatibility/)).
  The :80 listener stays; each HTTPRoute gets a redirect rule (new route, so the rollout is per-host and reversible).
- DNS: the wildcard record already exists (`dns.yml`, ADR 0004).

### The six routes, old name to new name

| Route | Old | New | What changes |
|---|---|---|---|
| belleshop-frontend | belleshop.local | belleshop.apps.home.arpa | Frontend is static `nginx:alpine`; the API is reached same-origin via `/api` on this host (the belleshop-api route), so there is **no API base URL and no CORS allowlist** — verified: no CORS middleware in `~/BelleShop/backend`, no cross-origin fetch in the frontend; a rename needs only the route hostname |
| belleshop-api | belleshop.local (path `/api`) | belleshop.apps.home.arpa | Same host as the frontend; nothing else |
| belleshop-api-host | api.belleshop.local | **api-belleshop.apps.home.arpa** | Still needed: "api.belleshop.local (belleshop-api-host) stays on stable during a canary" (`belleshop-deploy/base/backend-rollout.yaml`). Renamed to one label because the wildcard does not cover `api.belleshop.apps.home.arpa` |
| argocd-server | argocd.local | argocd.apps.home.arpa | Cookies are host-scoped (re-login once). Argo CD is not managed from this repo (no Application for it in `k8s/platform/apps/`; `bootstrap/root.yaml` manages only the apps); its TLS/insecure mode is unverified. The route targets `argocd-server:80` (verified in `k8s/platform/cluster-config/argocd-httproute.yaml`), which works in either TLS mode |
| grafana | grafana.local | grafana.apps.home.arpa | Cookies re-login. `root_url` is set nowhere — not in `k8s/platform/monitoring/values.yaml` and not in the chart defaults (verified by grep both) — so Grafana builds links from the request Host header; verify login and links after the rename, set `grafana.ini.server.root_url` only if they misbehave |
| argo-rollouts-dashboard | rollouts.local | rollouts.apps.home.arpa | Cookies only |

External consumers to update in the same change: `scripts/route-smoke.sh` (hosts array) and
`BelleShop/scripts/05-test-belleshop.sh` + `07-load-test-metrics.sh` (HOST_HEADER, and they curl `http://` — they
need `https://` plus `--cacert` once TLS is on; run before/after and diff, which is their purpose).

### Proxmox UI

PVE options ([Certificate Management](https://pve.proxmox.com/wiki/Certificate_Management)): default node cert
signed by the cluster CA; a custom cert goes in `/etc/pve/local/pveproxy-ssl.pem` +
`/etc/pve/local/pveproxy-ssl.key`; ACME support is Let's Encrypt-oriented (needs public DNS for http-01/dns-01
validation), which `home.arpa` cannot satisfy — ruled out.

Chosen: **key and CSR generated on `tuns`, signed outside the cluster.** The key never leaves the hypervisor; the
owner signs the CSR with the offline root (3-year leaf, calendar reminder at 30 months; the runbook records the
date). `pvenode`/file placement and a pveproxy restart are owner steps. This keeps the hypervisor's private key out
of Kubernetes entirely — a Certificate object there would put the key in a cluster Secret and force a hand export
at every renewal (draft error). Considered and rejected for now: trusting PVE's own cluster CA
(`/etc/pve/pve-root-ca.pem` copied to the Mac) — zero renewal work and PVE-native, but the CA key then lives on the
hypervisor, which is worse custody than the lab design.

### Named follow-up (out of scope here)

MySQL TLS for the `mysql-bao` path (ADR 0014 step 6 wanted it in week 6): needs MySQL configuration and a restart,
so it is its own change after the CA exists, not a step in this rollout.

## C. Proxmox firewall

Current state, from the repo: firewall off cluster-wide; per-VM UFW is the only filtering; break-glass from
Tailscale (`autogroup:member` to `tag:homelab-breakglass`, tcp 22 and 8006) is granted in `tailscale/policy.hujson`
and documented in `docs/entry-points.md` and ADR 0003.

**The trap that would fail the negative test:** pve-firewall automatically allows management traffic from the
auto-detected local network. "The local cluster network is automatically added to this IP set [management] …
(GUI, VNC, SPICE, SSH)" and under input DROP the exceptions still include "TCP traffic from management hosts to
port 8006 … port 22" ([firewall docs](https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html)). `tuns` sits on
192.168.1.0/24, so without further changes sectools would still reach 22/8006 and the negative proof would fail.

Owner-applied staged plan (host changes are never agent-applied):

1. **Confirm the recovery route first: the physical console.** noVNC is itself served on 8006, so it is not a
   recovery path if 8006 is misruled — the draft was wrong there.
2. **Arm a dead-man switch** before each risky stage (first confirm `at` is installed and `atd` is running on `tuns`): `echo pve-firewall stop | at now + 15 minutes`, canceled
   when the stage passes. "pve-firewall stop — Stop the Proxmox VE firewall service. Note, stopping actively
   removes all Proxmox related iptable rules rendering the host potentially unprotected"
   ([pve-firewall(8)](https://pve.proxmox.com/pve-docs/pve-firewall.8.html)).
3. **Override the auto-allow scope.** "The user can overwrite these values in the cluster.fw alias section"
   (same docs): set the `local_network` alias to the Mac only, and keep the `management` ipset at the Mac
   (192.168.1.121, a router fixed allocation per `clients.yml` — a reservation, not a guarantee; the tailscale
   path below is the second door if it ever changes). Run `pve-firewall localnet` first to record what the
   auto-detection would have allowed.
4. **Enter the rules with the firewall still disabled:** accept 22 and 8006 from the Mac and from `100.64.0.0/10`
   (tailscale0 — an independent path: if the LAN rule is wrong, SSH over the tailnet still works); accept
   established; outbound default-accept (PBS backup and restores are initiated by `tuns`, see below).
5. **Enable at datacenter level with input ACCEPT** (rules loaded, nothing denied), verify SSH and UI.
6. **Switch input to DROP.** Tests: Mac SSH+UI pass; tailscale0 SSH+UI pass (from a tailnet device, not the LAN);
   the negative proof from sectools: SSH and `curl https://192.168.1.181:8006` both fail.
7. VM traffic is unaffected: the datacenter firewall governs host rules; guest filtering is opt-in per VM NIC
   ("Each virtual network device has its own firewall enable flag"), and forwarded/bridged rules "are currently
   only possible when using the new nftables-based proxmox-firewall … ignored by the stock pve-firewall"
   ([zones/directions](https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html)).

Verified callers: Terraform (`bpg/proxmox ~> 0.117`, API on 8006) runs from the Mac; `scripts/connect-pve-to-pbs.sh`
and the backup/restore drills are initiated on `tuns` (outbound to pbs `.98:8007`); nothing inbound connects to
`tuns` — the Prometheus node-exporters run on the k8s nodes, and no scrape target or automation points at `.181`
(verified by grep over both repos and the monitoring values). The dead-man switch plus the physical console are
the recovery paths at every stage.

## D. Falco

- **Driver: modern eBPF probe** (Falco default; embedded, CO-RE, no kernel module or headers). Requires kernel BTF
  and ring buffer support ("usually, all versions >=5.8 are enough", [Falco docs](https://falco.org/docs/concepts/drivers/));
  6.8.0-147-generic qualifies. Least-privileged caps: `CAP_SYS_BPF`, `CAP_SYS_PERFMON`, `CAP_SYS_RESOURCE`,
  `CAP_SYS_PTRACE` (same page).
- **Chart: falco 9.2.2** (appVersion Falco 0.45.2, [releases](https://github.com/falcosecurity/charts/releases)).
  Default resources in the chart: requests `100m` CPU / `512Mi` memory, limits `1000m` / `1024Mi`
  ([chart values](https://github.com/falcosecurity/charts/blob/falco-9.2.2/charts/falco/values.yaml)) — set explicit
  values in the vendored app; three nodes, one agent each. Pin chart and image digests when vendoring.
- **Namespace:** new `falco` namespace with the PSA `privileged` label (like kube-flannel and metallb-system, live
  namespace labels). It carries no `homelab.arpa/admission: enforced` label, so the Week 4 Kyverno policies do not
  apply to it — verified from the policy files in `k8s/platform/kyverno-policies/` (they match that label) and the
  live labels; the limited cert cannot list clusterpolicies, so the live policy objects themselves were last
  verified during the Week 5 closeout, not today.
- **The proof rule needs a TTY.** "Terminal shell in container" has condition `… and proc.tty != 0 …`, priority
  `notice` ([rule source](https://raw.githubusercontent.com/falcosecurity/rules/main/rules/falco_rules.yaml)).
  So the proof must be `kubectl exec -it`, and the chart's default rule threshold (`priority: debug`, chart values)
  already admits notice — no tuning needed for the proof.
- **Noise:** `scripts/openbao-setup-mysql-rotation.sh` runs `kubectl exec -i` (no TTY) and invokes the `mysql`
  client, not a shell — the rule does not fire for it (verified from the script). Interactive shells opened by
  `belleshop-operators` fire by design; that is the proof, not noise. Tune other rules by priority/condition, never
  by raising the shell rule or the delivery threshold above notice.
- **Delivery: falcosidekick → Alertmanager.** falcosidekick (chart dependency 0.14.x) posts to Alertmanager
  (`hostport`, endpoint `/api/v2/alerts`, `minimumpriority`; default severity map sends notice→information,
  [chart values](https://github.com/falcosecurity/charts/blob/falcosidekick-0.14.1/charts/falcosidekick/values.yaml)).
  Alertmanager routes everything to `null` today, so a real receiver is required, closing the Week 5 gap:
  recommended SMTP with the credential in OpenBao pulled by ESO. **New work, not an existing pattern:** only `dev`
  has a SecretStore (in belleshop-deploy, per `docs/runbooks/openbao.md`; verified by grep — no SecretStore manifests
  in this repo), so this needs a monitoring ServiceAccount, SecretStore and OpenBao policy+role; the root token is
  revoked, so the owner mints a temporary one via `bao operator generate-root` (openbao.md §6) and revokes it again
  after.

**Proof:** `kubectl -n dev exec -it <pod> -- /bin/sh`, spawn a shell, and the Falco event travels the whole chain:
Falco log, falcosidekick forward, Alertmanager receiver.

## E. Admission (Week 4 Kyverno)

The image-verification and registry policies match namespaces labeled `homelab.arpa/admission: enforced` (policy
files in `k8s/platform/kyverno-policies/`, repo); only `dev` carries it (live labels). cert-manager, Falco and
kube-network-policies land in their own unlabeled namespaces, so nothing is weakened. If a platform component ever
must run inside `dev`, it pulls from `registry.home.arpa` like the app images; the Nexus proxy is the answer, not a
policy exception.

## F. Rollout plan

Who does what: agents write manifests and open PRs; Argo CD deploys what is merged; the owner applies host and
privileged changes (the Mac has no cluster-admin; the `olatunde` cert cannot read Secrets, cannot create pods or
cluster-scoped objects, cannot get Services in most namespaces, and cannot list clusterpolicies).

| # | Step | Reversible by | Who |
|---|---|---|---|
| 0 | Add `cert-manager`, `falco`, `kube-network-policies` to the AppProject destinations | Revert the PR | Agent (PR), Argo CD |
| 1 | B: root + intermediate + ClusterIssuer + wildcard Certificate + HTTPS listener + redirects; per-host route renames; route-smoke and BelleShop script updates | Revert the PRs; DNS wildcard covers both names | Owner (root, Mac), Agent (PRs), Argo CD |
| 2 | B: Proxmox UI cert (CSR on `tuns`, owner-signed, 3-year) | Remove the files, pveproxy restart | Owner only |
| 3 | A: DaemonSet; allow policies; default-deny `dev` + proof; then the other namespaces one at a time, webhook namespaces last, with the step checks of section A | Delete the DaemonSet (fail-open: traffic returns to pre-install behavior); delete policies one at a time | Agent (PRs), Argo CD, Owner (dummy create, rotation test) |
| 4 | A: remove NodePorts 30080/30081 (belleshop-deploy) | Revert the Service PR | Agent (PR), Owner (belleshop-deploy) |
| 5 | D: Falco + falcosidekick + Alertmanager receiver + OpenBao policy/role + monitoring SecretStore | Delete the falco app; revert the receiver route | Agent (PRs), Owner (generate-root, SMTP credential) |
| 6 | C: Proxmox firewall staged on `tuns` with dead-man switch | `pve-firewall stop`, or input ACCEPT, from the console | Owner only |

Order and why: B first (pure additions; unlocks TLS everywhere), A second (the core gap; the controller alone
changes nothing, so the risk is staged inside it), D third (independent once the receiver exists), C last
(owner-only, highest lockout risk; do it when nothing else is mid-flight and the console is within reach).

## Decisions for the owner

| # | Decision | Recommendation |
|---|---|---|
| 1 | Policy controller | kube-network-policies v1.1.2 (fail-open default, verdict logs, one-command rollback), watching for the release carrying PR #420; Canal v3.31.7 is the fallback if the day-one checks fail |
| 2 | CA tiers | Offline name-constrained root (10 y, owner custody) + intermediate in cert-manager (5 y, calendar at 4 y) |
| 3 | Alertmanager receiver | SMTP via OpenBao + ESO; the monitoring SecretStore is new work |
| 4 | Proxmox firewall timing | Last, with the dead-man switch and physical console confirmed first |
| 5 | Move the five Caddy VM roots to the lab CA now or later | Later, one host per PR; the lab CA proves itself on cluster and Proxmox first |
| 6 | New API host name | `api-belleshop.apps.home.arpa` (one label, wildcard-covered; the two-label form is not) |
| 7 | Proxmox UI cert source | CSR signed offline by the lab root, key never leaving `tuns`; alternative is trusting PVE's own cluster CA (zero renewal, worse custody) |

## Appendix: allow flows per namespace (live, 2026-11-01)

Source-address rules that decide correctness:

- **Same-node traffic** (kubelet probes) is always accepted by the agent (its `meta skuid 0` rule, per #417).
- **Cross-node node traffic** arrives with the source node's flannel address: the hostNetwork apiserver on master
  (.90) reaching a webhook on workernode2 appears as an address inside `10.244.0.0/24` (master podCIDR), the same
  masquerade pattern recorded for kube-proxy in `docs/runbooks/openbao.md`. Webhook allows therefore use the
  master's pod subnet, not `192.168.1.90/32` (draft error).
- **LoadBalancer masquerade:** `mysql-bao` has `externalTrafficPolicy: Cluster` (verified live), so MySQL sees the
  receiving node's address in `10.244.x.y` (ADR 0014 step 6). The receiving node is whichever one MetalLB elected for
  .244, not necessarily mysql-0's node, and it can move: `10.244.3.1` was observed (`docs/runbooks/openbao.md`) with
  workernode1 receiving. A rule for one node's subnet would break rotation on failover and would also admit every
  pod on that node. Allow 3306 from each node's single masquerade address: the flannel address when another node
  receives and the local bridge address when mysql-0's own node receives. Confirm these from the verdict log by
  moving the .244 announcement or by reading it on each node, before denying `dev`.
- **Gateway ingress:** the generated `homelab-gateway-nginx` Service is not readable with this cert; its
  `externalTrafficPolicy` is unverified. With Cluster the source at the gateway pod is the MetalLB leader node's
  pod-subnet address; with Local it is the LAN client. The allow covers both (and is harmless: any pod could reach
  the listener today anyway).
- **API server egress:** the agent hooks postrouting (per #417's analysis of `pkg/dataplane/controller.go`), so it
  sees the post-DNAT destination `.90:6443`, not the ClusterIP (which this cert cannot read; unverified). Allow
  `.90:6443`; belt-and-braces add the `kubernetes` ClusterIP after the owner reads it.

| Namespace | Allow (beyond intra-namespace, allowed everywhere) |
|---|---|
| `dev` | egress: DNS (53 UDP/TCP to kube-system/kube-dns pods); backend + backend-canary → mysql:3306. ingress: 8000/3000 from nginx-gateway pods; 8000 from monitoring (backend ServiceMonitor, 10s interval, verified in belleshop-deploy); 3306 from backend pods and from the node masquerade addresses (above, not a whole subnet) |
| `nginx-gateway` | ingress 80/443 from 192.168.1.0/24 and from 10.244.0.0/16 (both ETP cases). egress 6443 to .90 (control plane) and to the route backends: dev 8000/3000, monitoring grafana 3000, argocd 80/8080, argo-rollouts 3100 |
| `kyverno` | ingress 9443 from 10.244.0.0/24 (apiserver, cross-node). egress 6443 to .90; **egress 443 to `registry.home.arpa`**, because `verify-belleshop-images` checks signatures and digests there, and without it BelleShop deploys are rejected at admission |
| `external-secrets` | ingress 9443 from 10.244.0.0/24; **ingress 8080 from Prometheus**, because without this scrape the Week 5 `BelleShopDbEsoSyncFailed` alert goes silent. egress 443 to 192.168.1.95 (bao.home.arpa on sectools), 6443 to .90 |
| `argocd` | ingress 80 and 8080 on argocd-server from nginx-gateway pods. egress 443 to 192.168.1.83 (gitea.home.arpa), 6443 to .90, DNS; **repo-server egress 443 to the public Helm repos** in `k8s/platform/apps/` (charts.external-secrets.io, kyverno.github.io, prometheus-community.github.io; 0.0.0.0/0 minus the private ranges, since a policy can't name hosts). (redis, dex, repo-server, controller, applicationset, notifications, server are all intra-namespace, workernode1) |
| `argo-rollouts` | ingress 3100 from nginx-gateway pods. egress 6443 to .90; **egress 9090 to Prometheus in `monitoring`**, because `belleshop-deploy/base/rollout-analysis-template.yaml` queries it, and without this every canary analysis fails |
| `monitoring` | egress: 10250 to the three node IPs (kubelet scrapes), 10.244.0.0/16 (pod targets: node-exporter, kube-state-metrics, coredns, backend metrics), 6443 to .90 (operator), 9093 intra-ns (alertmanager). ingress: grafana 3000 from nginx-gateway pods; **Prometheus 9090 from argo-rollouts; Alertmanager 9093 from falcosidekick in `falco`**; scrapes from prometheus pods (intra-ns). Egress for the Alertmanager receiver (SMTP or webhook) and 443 to bao if a SecretStore lands here |
| `cert-manager` (new) | ingress 9443 from 10.244.0.0/24 (webhook). egress 6443 to .90. No external ACME (internal CA) |

This table is the starting set, not proof of completeness: review found four flows missing from the first pass that fail quietly or at a later deploy (registry, Helm repos, canary analysis, ESO scrape). Before each namespace's deny, compare against its Services, ServiceMonitors, webhooks and outbound config. After each deny, read the agent's DENY verdicts for at least one hour, and for `dev`, `argocd` and `kyverno` also run a real deploy, because their failures only appear then.

HostNetwork pods are outside policy scope: kube-flannel, kube-proxy, MetalLB speakers, the apiserver and etcd
static pods. coredns (kube-system, master + workernode1) needs no ingress allow because kube-system is never
denied.

## Sources

Checked 2026-11-01:

- [flannel README](https://github.com/flannel-io/flannel) — no native NetworkPolicy enforcement; [chart values](https://github.com/flannel-io/flannel/blob/master/chart/kube-flannel/values.yaml) — `netpol.enabled` deploys kube-network-policies
- [kube-network-policies docs](https://kube-network-policies.sigs.k8s.io/docs/) — v1.1.2, userspace NFQUEUE/nftables, selective capture, JSON verdicts; [flavors and flags](https://kube-network-policies.sigs.k8s.io/docs/user/flavors-and-architectures/) — `--fail-open` default true; [issue #417](https://github.com/kubernetes-sigs/kube-network-policies/issues/417) + [PR #420](https://github.com/kubernetes-sigs/kube-network-policies/pull/420) — node-to-pod exemption and its probe-tail bug
- [Calico 3.31 requirements](https://docs.tigera.io/calico/3.31/getting-started/kubernetes/requirements) — tests 1.32-1.35; [Canal install](https://docs.tigera.io/calico/3.31/getting-started/kubernetes/flannel/install-for-flannel) — canal.yaml v3.31.7
- [Cilium compatibility](https://docs.cilium.io/en/stable/network/kubernetes/compatibility/) — 1.20.4 e2e-tests 1.33-1.36
- [cert-manager releases](https://cert-manager.io/docs/releases/) — 1.21 supports 1.33-1.36
- [NGF Gateway API compatibility](https://docs.nginx.com/nginx-gateway-fabric/overview/gateway-api-compatibility/) — requestRedirect supported
- [Falco drivers](https://falco.org/docs/concepts/drivers/) — modern eBPF requirements and caps; [rule source](https://raw.githubusercontent.com/falcosecurity/rules/main/rules/falco_rules.yaml) — TTY requirement, notice priority; [falco chart](https://github.com/falcosecurity/charts/blob/falco-9.2.2/charts/falco/values.yaml) and [falcosidekick chart](https://github.com/falcosecurity/charts/blob/falcosidekick-0.14.1/charts/falcosidekick/values.yaml) — resources, priority threshold, Alertmanager output
- [PVE firewall docs](https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html), [pve-firewall(8)](https://pve.proxmox.com/pve-docs/pve-firewall.8.html), [PVE certificate management](https://pve.proxmox.com/wiki/Certificate_Management) — management ipset and local_network auto-allow, stop semantics, pveproxy cert files
- Name constraints: OpenSSL CHANGES, [Go 1.19](https://go.dev/doc/go1.19), [Apple HT208465](https://support.apple.com/en-us/HT208465), [Python ssl](https://docs.python.org/3/library/ssl.html)

## What was unverified

To confirm on day one, none blocking the design: kube-network-policies has no published Kubernetes version matrix
and no upstream production-readiness statement; its coexistence with iptables-mode kube-proxy is reported in the
wild (#417) but not promised upstream; v1.1.2 predates the #420 fix; busybox `wget` in the frontend image for the
denied-connection proof; the generated gateway Service's `externalTrafficPolicy`; the exact masqueraded source
address of the mysql-bao path (allow covers the node subnet); the `kubernetes` ClusterIP (this cert cannot read
Services); Argo CD's TLS mode and where its install values live (not in this repo, not Argo-managed); NGF
control-plane-to-data-plane port (covered by the intra-namespace allow); macOS name-constraint enforcement beyond
the security note and BetterTLS; where Terraform is run from (its provider credentials are outside the repo, so the
Mac is assumed from the repo comments); falco chart resource values may drift from the defaults cited — pin at
implementation along with image digests.
