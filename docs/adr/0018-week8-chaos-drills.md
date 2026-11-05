# ADR 0018: Week 8 chaos drills — plan, safety rails, and detection gaps

- Status: Accepted (owner, 2026-11-04, PR #65). Drill results are in docs/postmortems/.
- Date: 2026-11-04
- Owner: owner
- Last reviewed: 5 Nov 2026
- Next review: after remaining drill-5 follow-ups (blackbox `absent()`, BestEffort limits on other platform pods), or if a pre-drill alert PR changes detection

## Revision history

| Rev | Date | Change |
|---|---|---|
| A | 4 Nov 2026 | Initial proposal from live cluster and hypervisor facts |
| B | 5 Nov 2026 | Drill 5 ran: Fast alert at 2 m, no email, no stampede; see postmortem |
| C | 5 Nov 2026 | Follow-up: Alertmanager replicas=2 + hard anti-affinity; Prom/Grafana memory requests |

## Scope

In scope: design for the five Week 8 drills in the [ROADMAP](../../ROADMAP.md) — node loss, disk
full, bad deploy (Rollouts abort), expired cert, leaked secret — each with a hypothesis, an
owner-run injection, the exact live alert (or a named gap), abort/rollback, and what to record
in the postmortem.

Out of scope (and where it lives instead):

- Running any of the five drills — this ADR is design only. No `qm`, no kubectl mutate, no merge.
- Pre-drill PrometheusRules and ServiceMonitors — each gap below is its **own small PR**, with a
  `promtool` test, merged and firing-green before that drill starts.
- `etcd` restore — ROADMAP lists it separately from these five.
- Off-host PBS — architecture risk, not a Week 8 drill.

## Context

Week 7 proved that a git-shaped outage pages: belleshop-deploy `#26` / `#27`, six minutes
merge-to-page, 53 s recovery ([`docs/runbooks/belleshop-slo.md`](../runbooks/belleshop-slo.md)).
Week 8 asks for five *different* failures, each written up like
[`docs/postmortems/2026-11-03-pve-firewall-legacy-nat-outage.md`](../postmortems/2026-11-03-pve-firewall-legacy-nat-outage.md).

The lab is one hypervisor (`tuns` `.181`) and a two-worker cluster. OpenBao, Gitea and PBS are
deliberately **off** the cluster ([ADR 0014](0014-secrets-and-identity.md)), so a worker-loss
drill must not touch VMs `120` (sectools), `122` (gitea), `123` (pbs), or `108` (MasterNode).
`local-path` pins MySQL, Loki, Alertmanager and Prometheus to one node each; they cannot move.

This ADR is design only. Exact PromQL for *new* rules is pinned in the pre-drill PRs the same
way SLO rules were pinned in ADR 0017.

Verified on 2026-11-04 (read-only: `ssh tunsadmin@192.168.1.90 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf …'`; Grafana pod `wget` to Prometheus `/api/v1/rules` and `/api/v1/query`; `ssh root@192.168.1.181` `qm config` / `qm list` / `pvesm status`; no Docker, kind, or Mac-side containers):

| Area | Current state | Why it matters | Command |
|---|---|---|---|
| Node allocatable | Each node 2 CPU, ~3816 Mi memory. Ephemeral: master ~35.2 Gi, workers ~70.6 Gi | Memory, not CPU, is the stampede risk if a worker is drained | `kubectl describe nodes` Allocated resources |
| Requests / limits | master 1110m/606Mi (55%/15%, lim 22%); **wn1 1200m/2090Mi (60%/54%, lim 97%)**; **wn2 935m/1460Mi (46%/38%, lim 93%)** | Limits on both workers are already at the ceiling. Draining one worker onto the other will OOM even if requests fit | same |
| PVC pins (`local-path`) | `dev/mysql-data-mysql-0` 5Gi → **wn1**; `monitoring/storage-loki-0` 10Gi → **wn1**; Alertmanager 2Gi → **wn1**; Prometheus 5Gi → **wn2** | Those four pods stay Pending until their node returns. No volume expansion | `kubectl get pv -o custom-columns=…NODE…` |
| Placement that decides the drill | Gateway data-plane `homelab-gateway-nginx` **1/1 on wn2**; Prometheus **wn2**; Grafana **wn2**; **Alertmanager wn1**; **blackbox 1/1 on wn1**; **kube-state-metrics wn1**; Loki **wn1**; MySQL **wn1** | Losing wn2 blinds Prometheus and takes HTTPS `.240`. Losing wn1 keeps Prometheus/Grafana/Gateway but kills email, probes, ksm and MySQL | `kubectl get pods -A -o wide` |
| PDBs | **None** | Drain never waits. That is not safety; it is a stampede | `kubectl get pdb -A` |
| Worker VMs | `107` WorkerNode1 `.89` 2c/4G/80G, `agent=1`, `onboot=1`, snapshot parent `before-ansible-hardening`; `102` WorkerNode2 `.84` same shape | Injection is Proxmox `qm shutdown`, not a guest reboot and not `kubectl drain` | `qm config 107`; `qm config 102`; `qm list` |
| Disk free (`/` ext4, node-exporter) | master `.90` **38.0%** free; wn2 `.84` **48.8%**; wn1 `.89` **60.3%** | Hitting live `NodeFilesystemAlmostOutOfSpace` (5% warn / 3% crit, `for 30m`) means writing tens of GiB onto a node that holds MySQL, Loki, Prometheus or etcd | `node_filesystem_avail_bytes{mountpoint="/"} / …size…` |
| kubelet evictionHard | `nodefs.available=10%`, `nodefs.inodesFree=5%`, `imagefs.available=15%`, `imagefs.inodesFree=5%`, `memory.available=100Mi`. No evictionSoft | A fill that reaches 10% free evicts pods **before** the 5% filesystem warning has finished its 30m `for` | kubelet `configz` |
| PVC usage metrics | `count(kubelet_volume_stats_capacity_bytes)` = **empty**. `KubePersistentVolumeFillingUp` is loaded but cannot fire | Filling a PVC is invisible to Prometheus today, and local-path does not enforce quota (fill the PVC, fill the node) | `/api/v1/query` |
| Live disk alerts | `NodeFilesystemAlmostOutOfSpace` warning `<5%` / critical `<3%`, both `for 1800`. `NodeFilesystemSpaceFillingUp` is predict_linear over 6h — useless for a drill | The only stock disk pages are too deep to drill safely | `/api/v1/rules` |
| Live node alerts | `KubeNodeNotReady` / `KubeNodeUnreachable` **`for 900`** (15 min), severity warning. `TargetDown` `>10%` of a job `for 600`. `Watchdog` firing to the null receiver | 15 min is slow; ksm lives on wn1 so wn1-loss also kills the Ready-condition source | `/api/v1/rules` |
| Rollout | `dev/backend` canary: **10% → pause 15s → 50% → pause 15s → analysis `success-rate`**. Image is a signed digest. `selfHeal: true` on the Argo app (Week 7 lesson: do not kubectl-scale) | Analysis runs **at 50% weight**, not 10% | `kubectl -n dev get rollout backend` |
| AnalysisTemplate `dev/success-rate` | PromQL: 5xx rate / all `job="backend"` (cluster-wide, **not canary-only**). `successCondition: result[0] <= 0.05`. `interval: 10s`, `count: 3`, **`failureLimit: 1`** | First bad sample aborts. Query includes stable+canary pods | `kubectl get analysistemplate -A -o yaml` |
| HTTPRoute canary | `belleshop-api` weights `backend=100`, `backend-canary=0` (idle). SLO probes: shop-home + shop-api every **15s** through the Gateway; `shop-api-debug` is not in the SLO | At 50% canary, `/api/healthz` probes **do** hit the canary. A 5xx healthz canary can burn the SLO | `kubectl -n dev get httproute belleshop-api` |
| Certificates | One Certificate: `nginx-gateway/apps-home-arpa`, `dnsNames: ["*.apps.home.arpa"]`, `duration: 2160h` (90d), `renewBefore: 720h` (30d), `notAfter: 2027-01-31T20:38:31Z`, issuer `lab-ca`. Ready | The Gateway listener terminates **only** this wildcard Secret. Any `*.apps.home.arpa` probe sees this leaf | `kubectl get certificate -A` |
| cert-manager scrape | Services on `:9402` exist. **No ServiceMonitor.** `certmanager_certificate_expiration_timestamp_seconds` **absent** (confirmed) | cert-manager cannot alert on expiry until a SM lands, and netpol currently omits 9402 on purpose | `/api/v1/query`; `k8s/platform/cert-manager/manifests/netpol-allow.yaml` |
| `probe_ssl_earliest_cert_expiry` | Present on all three blackbox instances; value `1801427911` = **2027-01-31T20:38:31Z** (matches the wildcard). **No alerting rule** uses it | Detection gap for TLS expiry | `/api/v1/query`; `/api/v1/rules` |
| Secret detection | pre-commit `gitleaks` v8.30.0 on this repo; Jenkins `ci/gates/secrets.sh` (Gitleaks 8.30.1) on BelleShop. Gitea push-hook gitleaks is still an **open** action item from the 2026-10-25 postmortem | A `--no-verify` push is not blocked at Gitea | `.pre-commit-config.yaml`; `docs/postmortems/2026-10-25-gitea-rce-cve-2026-60004.md` |
| Rotation docs | `homelab-bot` token `agent-pushes`: delete + create. OIDC client: Gitea regenerate + `scripts/openbao-breakglass.sh root-run oidc <consumer> --overwrite` | Real rotate must be a credential already in [`docs/credentials.md`](../credentials.md) | credentials table |
| Background alert | `BelleShopAvailabilityBurnSlow` was **firing** (warning) at survey time; Fast/Medium inactive | Do not use Slow as a drill signal | `/api/v1/rules` |

Worker host `df` over SSH as `tunsadmin` is still denied. Free-space percentages above are
node-exporter on `/`, which is the kubelet root filesystem.

## Options considered

### Which worker to lose

| Option | For | Against |
|---|---|---|
| **`qm shutdown 107` (workernode1) — chosen** | Prometheus, Grafana and the Gateway stay up, so the failure is observable. MySQL/Loki/AM outage is bounded to BelleShop + log ingest + email | No Alertmanager (no email). No blackbox (SLO series go stale, not fail). No kube-state-metrics (`KubeNodeNotReady` will not evaluate). TargetDown is the live detector |
| `qm shutdown 102` (workernode2) | AM and blackbox stay | Prometheus PVC is on wn2 — **no rules evaluate**. Gateway 1/1 is on wn2 — all `*.apps.home.arpa` die. Blind drill |
| Drain then reboot (existing [`drained-node-reboot.md`](../runbooks/drained-node-reboot.md)) | Known procedure | Drain **moves** stateless pods onto the other worker. wn2 limits already 93%; adding wn1's non-PVC pods exceeds allocatable. Not a loss drill, a stampede |
| Master (`108`) | — | Control plane. Out of scope |

### Disk-full injection

| Option | For | Against |
|---|---|---|
| **Throwaway pod, `emptyDir.sizeLimit: 256Mi`, `dd` until eviction, via git — chosen** | Hard cap. Does not aim at MySQL/Prometheus/Loki PVCs. Reverted by reverting the PR | Will **not** trip `NodeFilesystemAlmostOutOfSpace` (node free stays ~49–60%). Relies on a new eviction/canary alert (gap) |
| `fallocate` on a worker root to the 5% line | Hits the live node-exporter rule | Tens of GiB on a node that holds a pinned PVC or, on master, etcd. kubelet evicts at 10% **during** the fill. Forbidden |
| Fill a PVC | Looks like a real app bug | local-path does not cap; fills the node. `kubelet_volume_stats_*` is absent, so `KubePersistentVolumeFillingUp` stays silent |

### Bad deploy

| Option | For | Against |
|---|---|---|
| **PR in `belleshop-deploy`: same signed digest, breaking env that 5xxes application routes but keeps `/healthz` 200 — chosen** | Kyverno Deny still sees a signed digest. AnalysisTemplate watches `http_requests_total{status="5xx"}`. SLO probes hit `/` and `/api/healthz` and should stay green if healthz is honestly 200 | Needs a flag or env the app already understands, or a tiny CI-built image. Confirm healthz with a canary pod *before* merge if unsure |
| CI image that 5xxes `/healthz` | Analysis fails fast | At 50% weight, ~50% of SLO probes fail for ~30–45 s. Fast-burn threshold is ~7.2% over 5m; 45 s of 50% is ~7.5% and **can page** |
| `kubectl set env` / `kubectl patch` | Fast | `selfHeal: true` (and platform-root) reverts it, same failure mode as Week 7 |

### Expired cert

| Option | For | Against |
|---|---|---|
| **Dedicated Certificate `chaos-expiry.apps.home.arpa` + extra Gateway `certificateRefs` SNI, never touch `apps-home-arpa-tls` — chosen, with a SNI proof first** | Wildcard stays. Blackbox `probe_ssl` can target that host only | If NGF ignores extra refs and presents one cert for every SNI, **abort** and fall back to an in-cluster TLS server (ClusterIP) plus a Probe. Do not put an expired leaf on the shared listener |
| Shorten `apps-home-arpa` duration / delete the Certificate | Hits every shop and admin UI | Forbidden. Must-not |
| Pause cert-manager | Stops wildcard renewal too | 30-day renewBefore means a one-hour pause is probably safe, but it is still a cluster-wide lever. Last resort only |

## Decision

1. **Order the drills safest-first** (see the sequence table). Owner-present for disk-full and
   node-loss. Bad-deploy and leaked-secret can be remote. Cert drill is owner-present until the
   SNI proof passes.
2. **Prefer git over kubectl** wherever Argo self-heal would fight the fault (bad deploy, disk
   canary pod, chaos Certificate). Node-loss is hypervisor-shaped; leaked-secret rotate is
   Gitea + OpenBao-shaped.
3. **Do not drain a worker for the loss drill.** `qm shutdown 107` (ACPI, guest agent is on).
   Do not `qm stop 107` — MySQL, Loki and Alertmanager volumes sit on that disk.
4. **Do not fill a node filesystem or a PVC** to the live 5%/3% thresholds. Disk drill is a
   size-capped emptyDir canary plus a **new** alert, shipped first.
5. **Do not expire or replace `*.apps.home.arpa`.** Chaos hostname only.
6. **Ship detection PRs before the drill they belong to.** Missing alerts are findings, not
   improvisation on the day.
7. **Each drill writes a postmortem from [`docs/postmortems/TEMPLATE.md`](../postmortems/TEMPLATE.md)**
   with detect / mitigate / recover timestamps in America/Chicago.

### Sequence (safest first)

| # | Drill | Owner present? | Calendar time | Must not happen |
|---|---|---|---|---|
| 1 | Leaked secret (fake PR + rotate `oauth2-proxy-alertmanager`) | No | ~25 min | Do not rotate `argocd-read` / `argocd-readonly` (that broke Argo CD on 2026-11-04). Do not rotate `agent-pushes` in the middle of other agent work unless `.envrc` is updated in the same sitting |
| 2 | Bad deploy (Rollouts abort) | No, but owner merges | ~20 min | Unsigned image; `kubectl` patch; leaving canary at 50% |
| 3 | Expired cert (chaos hostname) | Yes until SNI proof | ~30 min | Wildcard Secret, `lab-ca` ClusterIssuer, Proxmox `/etc/pve/nodes/*/pve-ssl.pem`, Caddy VM roots |
| 4 | Disk full (emptyDir canary) | Yes | ~20 min | `fallocate`/`dd` on wn1, wn2 or master root; MySQL/Prometheus/Loki PVC |
| 5 | Node loss (`qm shutdown 107`) | **Yes, at a console that can `qm start`** | ~30–45 min (includes 10 min TargetDown `for`) | VMs 102/108/120/122/123; `qm stop`; drain |

---

## Drill 1 — Leaked secret

**Hypothesis.** When a well-known fake cloud token lands in a PR on `homelab-platform`,
`gitleaks` (pre-commit, and Jenkins `secrets.sh` if that pipeline runs) refuses the change
within one commit/CI run. Gitea itself does **not** block it today. When a real low-blast
OIDC client secret is rotated, that one consumer (Alertmanager UI login) starts working with
the new secret and the old secret is dead; Gitea, OpenBao unseal, and other OIDC consumers
are untouched.

**Injection (detection half, git).**

1. Branch. Add a file `docs/chaos/gitleaks-canary.txt` whose only contents are a **documented
   gitleaks test token**, not a real credential — e.g. the AWS example `AKIAIOSFODNN7EXAMPLE`
   plus `gitleaks` documentation's generic high-entropy pattern. Commit **without**
   `--no-verify` first.
2. Expect the local `gitleaks` hook to fail. That is the detect event. Do not merge.
3. Optional proof of the Gitea gap (owner only): a throwaway branch pushed with
   `--no-verify` to show Gitea accepts it; delete the branch immediately. Record that as a
   finding, not as a standing leak. Never push a real token.

**Injection (revoke+rotate half, real, low blast).** Rotate
`oauth2-proxy-alertmanager` only (one UI, logs everyone out of Alertmanager, does not break
Argo CD or agent pushes):

1. Gitea → OAuth2 application `oauth2-proxy-alertmanager` → Regenerate Secret. Copy once.
2. `scripts/openbao-breakglass.sh root-run oidc oauth2-proxy-alertmanager --overwrite`
   (owner terminal; script already exists, `--overwrite` is required or the re-run is a skip).
3. Force the ExternalSecret to re-read OpenBao, THEN restart (its `refreshInterval` is 1h, so a restart alone
   reloads the old Secret; found in the drill, see the 2026-11-04 postmortem):
   `kubectl -n monitoring annotate externalsecret oauth2-proxy-alertmanager force-sync=$(date +%s) --overwrite`,
   wait ~20 s, then `kubectl -n monitoring rollout restart deploy/oauth2-proxy-alertmanager`.
4. Prove: old client secret is rejected at Gitea; new login at the Alertmanager gate works.

**Detect.** No Prometheus rule. Detectors are `gitleaks` (pre-commit v8.30.0; Jenkins gate)
and the human following [`docs/credentials.md`](../credentials.md) rule 4, "Leaked = rotated."
**Gap:** Gitea has no pre-receive gitleaks (open since 2026-10-25). A follow-up PR, not a
PrometheusRule.

**Abort / rollback.** Close the PR; delete the canary branch. If `--overwrite` was applied,
there is no rollback to the old OIDC secret — that is the point. If ESO/proxy is wedged,
re-run `--overwrite` with the still-current Gitea secret; do not restore a leaked value.

**Must not.** Commit a live token. Rotate `argocd-read`. Print the new secret into chat, git,
or the postmortem.

**Record.** Time the hook failed; time the Gitea regenerate; time `--overwrite` returned;
time the UI login worked; time the old secret was confirmed dead.

---

## Drill 2 — Bad deploy (Rollouts abort)

**Hypothesis.** When `belleshop-deploy` merges a backend change that raises `job="backend"`
5xx **above 5%** while the image digest stays signed, Argo Rollouts aborts during
`success-rate` (first failing 10s sample, `failureLimit: 1`) and returns traffic to stable
(`backend-canary` weight 0). SLO Fast/Medium do **not** page if `/api/healthz` stays 200.

**Injection (git, owner merge).** In `belleshop-deploy` `base/backend-rollout.yaml` (not
this repo):

1. Keep `image: registry.home.arpa/belleshop/belleshop-backend@sha256:…` (live digest is
   `sha256:102232e2e418b23e77c22bac6c0c30678651c519b1cf732c8fa8965f3f61ba95` as of this
   survey — re-read at drill time).
2. Add or flip an env that 5xxes a **non-healthz** route (preferred). If the app has no such
   flag, build a signed image in CI whose `/healthz` stays 200 and `/` or `/token` returns
   5xx, and let Jenkins open the usual digest PR.
3. Owner merges. Watch `kubectl -n dev get rollout backend --watch` and the Rollouts
   dashboard. Analysis starts **after** 10% (15s) and 50% (15s).

Do **not** `kubectl argo rollouts abort` unless the analysis has not aborted by ~90 s after
hitting the analysis step — that is the abort criterion for a stuck canary.

**Detect.** Not a Prometheus alert. Detector is Rollouts: AnalysisRun Failed, Rollout
Aborted, HTTPRoute weights restored to 100/0. Optional: `TargetDown` does not apply.
Confirm `BelleShopAvailabilityBurnFast` stays inactive (Grafana, not email wait).

**Abort / rollback.** If analysis does not fail: owner merges a revert PR (same path as
`#27`). If healthz is 5xx and Fast-burn starts to fire, merge the revert immediately; do
not wait for the 5m window to fill. `kubectl argo rollouts undo` is last resort and fights
self-heal — follow with a git revert.

**Must not.** Unsigned or `:latest` image (Kyverno Deny in `dev`). `replicas: 0` (that is
the Week 7 SLO drill, already done). Leaving the breaking env on `main`.

**Record.** Merge time; weight 10% / 50% / analysis-start; AnalysisRun failed; aborted;
weights 100/0; Fast-burn still inactive (or the time it fired — that is a finding).

**Pre-drill note.** If we cannot keep `/healthz` green, skip this drill until a signed
healthz-safe image exists. Paging the SLO is a different experiment and already proven.

---

**Result 2026-11-04 (hypothesis FAILED):** the `success-rate` analysis passed the bad canary (30 s of checks on
`rate[1m]` ran before the canary's errors were scraped) and later aborted the good revert (stable + canary pods are
counted together). Recovery needed `promoteFull`. See the
[postmortem](../postmortems/2026-11-04-drill2-bad-deploy.md).

---

## Drill 3 — Expired cert

**Hypothesis.** When a **dedicated** leaf for `chaos-expiry.apps.home.arpa` is past
`notAfter`, blackbox `probe_ssl_earliest_cert_expiry` for **that instance** drops below the
alert threshold and a new rule pages, while `probe_ssl` on the three shop URLs stays at
2027-01-31 and the wildcard Gateway listener keeps serving BelleShop.

**Live detection today: none.** No rule references `probe_ssl_*` or cert-manager. The
metric `certmanager_certificate_expiration_timestamp_seconds` is not scraped.

**Pre-drill PR (required).**

1. ServiceMonitor + netpol allow Prometheus → cert-manager `:9402` (today deliberately
   closed). Prove `certmanager_certificate_expiration_timestamp_seconds` is non-empty.
2. PrometheusRule + `promtool` test (same layout as
   `k8s/platform/monitoring/rules/belleshop-slo.test.yaml`):

```yaml
# HomelabTlsCertExpiringSoon — warning 21d, critical 7d, for 1h
- alert: HomelabTlsCertExpiringSoon
  expr: |
    (probe_ssl_earliest_cert_expiry{job="blackbox"} - time()) / 86400 < 21
  for: 1h
  labels: { severity: warning }
```

A second rule on `certmanager_certificate_expiration_timestamp_seconds - time() < 7*86400`
covers Certificates that are not on a Probe.

**Injection (git, after the SM+rule are live).**

1. Certificate in a labelled namespace (`homelab.arpa/gateway-routes: "true"`),
   `secretName: chaos-expiry-tls`, `dnsNames: ["chaos-expiry.apps.home.arpa"]`,
   `issuerRef: lab-ca`, **`duration: 2h`**, `renewBefore: 90m`. HTTPRoute to a tiny
   `return 200` backend (or an existing safe Service).
2. **SNI proof, still valid cert:** add `certificateRefs: [{name: apps-home-arpa-tls},
   {name: chaos-expiry-tls}]` on the https listener. `openssl s_client -servername
   chaos-expiry.apps.home.arpa` must show the chaos leaf; `-servername
   belleshop.apps.home.arpa` must still show the wildcard. If both show the same leaf,
   **revert the Gateway patch and stop** — fall back to an in-cluster TLS server, do not
   expire anything on the shared listener.
3. After SNI is proven: patch the chaos Certificate `issuerRef` to a **non-existent**
   Issuer so renew fails. Wait out `notAfter` (≤2 h). Do not scale cert-manager to 0.

**Abort / rollback.** Revert Gateway `certificateRefs` to wildcard-only first. Delete the
HTTPRoute, Certificate and chaos Secret. `cmctl renew apps-home-arpa` only if the
wildcard was touched (it must not have been).

**Must not.** Edit `apps-home-arpa` duration/dnsNames/secretName. Delete ClusterIssuer
`lab-ca`. Replace Proxmox or Caddy certificates as part of this drill.

**Record.** Time SM scrape appeared; time SNI proof passed (or aborted); time issuer
patched; time `probe_ssl` for the chaos instance crossed 21d/0d; time the new alert
fired; time wildcard shop probes still succeeded; time revert.

---

## Drill 4 — Disk full

**Hypothesis.** When a labelled canary pod on **master** (no app PVCs) writes to an
`emptyDir` until `sizeLimit: 256Mi`, kubelet evicts that pod, a new alert fires within
two minutes, and MySQL / Prometheus / Loki / Gateway disk usage does not move.

**Live detection today: insufficient.** `NodeFilesystemAlmostOutOfSpace` is 5%/3% for 30m —
not drillable. `KubeNodeEviction` exists at **info**. `KubePersistentVolumeFillingUp` cannot
fire (`kubelet_volume_stats_*` absent).

**Pre-drill PR (required).** `HomelabDiskCanaryEvicted` (warning) on kubelet eviction
events or `kube_pod_container_status_last_terminated_reason{reason="Evicted"}` for
`app=homelab-disk-canary`, `for: 1m`, with a `promtool` test. Optionally start scraping
kubelet volume stats so PVC alerts become real — that is a separate PR and **not** used
as this drill's injection.

**Injection (git).** Manifest (Argo-managed, default-deny-friendly): one Pod,
`nodeSelector: kubernetes.io/hostname: master`, `priorityClass` default (not
cluster-critical), container `dd if=/dev/zero of=/scratch/fill bs=1M count=512` with
`volumeMounts` emptyDir `sizeLimit: 256Mi`. Owner merges, watches eviction, then merges
the revert (delete the pod spec).

If the canary lands on a worker instead, **abort** (do not let it run next to a PVC).

**Abort / rollback.** Revert PR. If the pod is somehow uncapped (sizeLimit ignored — treat
as an incident): `qm` is **not** the fix; delete the pod via git. If nodefs on master
crosses 15% free, stop and revert; do not wait for 10% evictionHard.

**Must not.** `fallocate` on `.89` / `.84` / `.90` root. Fill any of the four PVCs. Run
the canary on wn1 or wn2.

**Record.** Merge time; pod Running; first Evicted; new alert firing; `node_filesystem_avail`
percent on all three nodes unchanged vs baseline; revert; nodefs still unchanged.

---

## Drill 5 — Node loss

**Hypothesis.** When WorkerNode1 (VM `107`) is ACPI-shut down, Prometheus on wn2 keeps
evaluating rules. Within **10 minutes** `TargetDown` fires for jobs that lost a material
fraction of targets (node-exporter 1/3, plus blackbox and kube-state-metrics as whole
jobs). BelleShop `/api` fails because MySQL is pinned to wn1. Gateway and Grafana stay
up. Gitea, OpenBao and PBS stay up. After `qm start 107` and node Ready, mysql/loki/AM
bind their local-path volumes and recover without restore-from-PBS.

**Result (2026-11-05).** Short window (~5 min, under the 300 s unreachable taint):
`HomelabKubeNodeNotReadyFast` fired at 2 m (Grafana only; **no email**). `TargetDown`
did not fire (`for: 600`). No reschedule, 0 Evicted. MySQL remounted; wrong-password
login 400. Shop impact ~7.5 min.
[postmortem](../postmortems/2026-11-05-drill5-node-loss.md).

**Injection (owner, hypervisor).** Not git. Do **not** drain.

```sh
# baseline
ssh tunsadmin@192.168.1.90 'sudo -n kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes,pods -A -o wide'
# record nodefs, Watchdog, TargetDown, shop curls

ssh root@192.168.1.181 'qm status 107'
ssh root@192.168.1.181 'qm shutdown 107'   # ACPI; agent is enabled
# wait until qm status is stopped; kubectl node workernode1 NotReady / unreachable

# rollback
ssh root@192.168.1.181 'qm start 107'
# wait node Ready; mysql-0, loki-0, alertmanager-0 Running; shop-api probe 1
```

If `qm shutdown` is still running after 2 minutes, **abort** — do not `qm stop`. Debug
guest agent / ACPI from the Proxmox console.

**Detect (live, no new rule strictly required, but 15m Ready is too slow).**

| Rule | Live? | Will it fire for `107` down? |
|---|---|---|
| `TargetDown` (`general.rules`, `for 600`, warning, `>10%` of targets in a job) | **Yes** | **Yes** for `node-exporter` (33%). Also for `kube-state-metrics` and blackbox as 100% down |
| `KubeNodeNotReady` (`for 900`, warning) | Yes | **Probably no** — ksm is on wn1, so the condition series goes stale/absent |
| `KubeNodeUnreachable` (`for 900`) | Yes | Same ksm dependency |
| `BelleShopAvailabilityBurnFast` | Yes | **Unreliable** — blackbox is on wn1, so `probe_success` goes stale rather than 0 |
| Alertmanager email | AM pod on wn1 | **No email** until 107 is back. Watch Grafana / Prometheus UI |

**Pre-drill PR (recommended, not blocking if we accept UI-only detection).**
`HomelabKubeNodeNotReadyFast`: `up{job="node-exporter"} == 0` `for: 2m`, severity
warning, so we do not wait 10–15 minutes. Still does not restore email.

**Abort / rollback.** `qm start 107` immediately if: any of 102/108/120/122/123 change
state; Prometheus or Gateway on wn2 die; `qm shutdown` hangs. After start, do not drain
or delete PVC pods — they must remount.

**Must not.** `qm stop 107`. `qm shutdown 102` (Prometheus). Touch master, gitea,
sectools, pbs. `kubectl drain workernode1`. Restore MySQL from backup "to be safe" unless
the volume is actually corrupt (that would be a different incident).

**Record.** `qm shutdown` issued; node NotReady; first TargetDown; shop-home vs shop-api
from the Mac; AM email **absent** (finding); `qm start`; node Ready; mysql/loki/AM Ready;
probes 1; TargetDown resolved.

Expected downtime of pinned pods: the whole window 107 is stopped, plus kubelet/plugin
start (typically a few minutes; the 2026-10-29 drained reboot was ~10 min/node).

---

## Alert gaps to ship as their own PRs

Do these **before** the matching drill. Copy the SLO pattern: PrometheusRule CR with
`release: prometheus-stack` plus `k8s/platform/monitoring/rules/*.rules.yaml` +
`*.test.yaml` and `promtool test rules`.

| Gap | Drill | Proposed alert | Why the live rule is not enough |
|---|---|---|---|
| No TLS expiry alert; cert-manager unscrapeable | 3 | SM `:9402` + `HomelabTlsCertExpiringSoon` on `probe_ssl_earliest_cert_expiry` and on `certmanager_certificate_expiration_timestamp_seconds` | Zero rules mention SSL/cert-manager |
| Disk pages only at 5%/3% for 30m; PVC stats absent | 4 | `HomelabDiskCanaryEvicted`; later a kubelet volume-stats scrape | Filling to 5% is unsafe; `KubePersistentVolumeFillingUp` is dead code today |
| Node Ready `for 900`; ksm on the node we plan to kill | 5 | `HomelabKubeNodeNotReadyFast` on `up{job="node-exporter"}==0` for 2m | `KubeNodeNotReady` will not evaluate during the chosen drill |
| Gitea does not run gitleaks | 1 | Gitea pre-receive or Actions — not PromQL | `--no-verify` is enough to land a secret |

## Abort criteria that apply to every drill

- Any unexpected VM besides the target changes state (`qm list`).
- Gitea (`https://gitea.home.arpa`), OpenBao (`https://bao.home.arpa`) or PBS becomes
  unreachable.
- Wildcard shop TLS (`openssl s_client -servername belleshop.apps.home.arpa`) changes
  issuer/`notAfter` during a non-cert drill, or at all during the cert drill except on
  the chaos hostname.
- Nodefs free on any node drops more than ~2 percentage points during the disk canary.
- Owner is not able to `qm start 107` (node-loss is then postponed).

## What to record (every postmortem)

Use [`docs/postmortems/TEMPLATE.md`](../postmortems/TEMPLATE.md). Minimum timestamps
(America/Chicago):

1. **Detect** — first human-visible or alert-visible signal.
2. **Mitigate** — injection stopped or traffic restored (abort, revert merge, `qm start`).
3. **Recover** — probes/alerts/UI back to the pre-drill baseline.

Plus: hypothesis pass/fail, which live rule fired (name + `for`), what did not fire,
must-not list checked, follow-up PRs.

## Consequences

- Week 8 is a sequence of small PRs (alerts, cert-manager scrape, chaos manifests) plus
  five owner-gated injections, not a single merge.
- Node-loss will **not** demonstrate Alertmanager email until AM is replicated off wn1
  (out of scope; would need a second PVC or a different storage class).
- Disk-full will **not** demonstrate `NodeFilesystemAlmostOutOfSpace` unless the lab
  later adds a disposable disk. That is accepted.
- OpenBao/Gitea/PBS surviving worker loss is a stated goal of ADR 0014; this ADR is the
  first planned proof. Do not weaken that by shutting those VMs "to make it interesting."

## Follow-ups (after the five drills)

- **Alertmanager HA + Prom/Grafana requests** (`fu-alertmanager-ha`): two AM replicas
  with hard hostname anti-affinity so email survives one worker; Prometheus and Grafana
  get memory/CPU **requests** (no Prometheus memory **limit**). External Watchdog
  heartbeat is an owner account, not this PR. See `docs/runbooks/monitoring.md`.
