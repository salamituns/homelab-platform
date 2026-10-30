# ADR 0011: CI platform: rebuild Jenkins, SonarQube and Nexus as code; one set of security gates

- Status: Accepted
- Date: 2026-10-29

## Context

Week 3 needs a pipeline that can block a release. BelleShop's `Jenkinsfile` runs today, but:

- Every check ends in `|| true`, so nothing can fail the build.
- There is no registry. The image goes to the nodes as a `.tar` over SSH and is loaded with `sudo ctr import`.
  Jenkins therefore holds a key with sudo on all three k8s nodes, with `StrictHostKeyChecking=no`.
- Manifests use `:latest`. The repo URL and push token point at the retired Gitea (UbuntuNew),
  and the token is in the git URL.

The servers behind it (SonarQuality 104 / .86, JenkinsCICD 105 / .88, Nexus 106 / .87) were built by hand
in 2026, before this repo. They are not in Terraform. The baseline role covers them, but nothing in git
describes their applications, versions or credentials.

Industry context: new projects mostly use GitHub Actions or GitLab CI. Jenkins is still everywhere in
large companies. Gitea Actions runs GitHub Actions workflow syntax, so the lab can practise both.

## Decision

| Question | Choice | Why |
|---|---|---|
| Servers | Rebuild all three with Terraform (`modules/vm`) and Ansible roles; **start fresh** | Same path as gitea and pbs. Nothing on the old hosts is worth carrying over, and their credentials are treated as burned |
| Old VMs | Shut down (`onboot 0`) **before** the new ones are built; delete after 2026-11-28 | Frees 12 GB RAM and their IPs. Nothing depends on them: no registry is in use and the Jenkins job points at a dead Gitea |
| Addresses | New VMs reuse `.86`/`.87`/`.88`; DNS names unchanged; agent on `.93` | No DNS, Tailscale policy or address plan changes. Consequence: the Mac's `known_hosts` entries for those IPs change |
| Nexus | `nexus` VMID 124, .87, 4 cores / 6 GB, 40 GB + 100 GB data disk; Nexus Repository Community Edition, version pinned | The registry everything else needs, so it is built first. CE limits (components, requests/day) are far above lab use |
| Registry | Docker hosted repo `belleshop`, served as `registry.home.arpa` by Caddy to a localhost connector | Nodes **pull** images; nobody pushes into nodes. A separate hostname avoids Nexus' port and path rules for Docker |
| Registry users | `ci-push`: push to `belleshop` only. `k8s-pull`: read only, as an imagePullSecret. Anonymous off | A leaked CI credential cannot read or overwrite other repos; a leaked node credential cannot push |
| SonarQube | `sonarqube` VMID 125, .86, 2 cores / 4 GB; Community Build + PostgreSQL, versions pinned; `vm.max_map_count` set by Ansible | Its embedded Elasticsearch refuses to start without the sysctl |
| Jenkins controller | `jenkins` VMID 126, .88, 2 cores / 2 GB; LTS from the Jenkins apt repo, pinned. **JCasC** for config, `plugins.txt` with pinned versions, jobs defined from the repo. **0 executors** | Rebuild and it comes back identical. Builds never run on the controller, which holds every credential |
| Jenkins agent | `ci-agent` VMID 127, .93, 2 cores / 4 GB, 60 GB; Docker, Trivy, Syft, Cosign, Gitleaks pinned; connects **inbound** to the controller over HTTPS (WebSocket) | The agent runs untrusted build code, so it lives on its own VM. Inbound means the controller needs no SSH key anywhere |
| Gates | Written once in `ci/` scripts (secrets, SAST, dependency scan, image scan, SBOM, sign) that every pipeline calls | One definition of "safe to ship". The Jenkinsfile and future Actions workflows only call it ("paved road") |
| Gate rules | Fail on: any Gitleaks finding; SonarQube quality gate failed (`sonar.qualitygate.wait=true`); Trivy HIGH/CRITICAL with a fix available. Exceptions only in a reviewed `.trivyignore`, each with a reason and expiry | No `\|\| true`. An unfixable CVE does not block the release, but it shows up in the report and the SBOM |
| Artifacts | Image referenced by **digest** in git; Syft SBOM (SPDX) attached; image and SBOM attestation signed with Cosign | Week 4 (Kyverno) verifies the signature at admission |
| Cosign key | Key pair generated on the Mac; private key + password as Jenkins credentials; public key in git | Week 5 moves signing secrets to the secrets manager |
| Triggers | Gitea webhook to Jenkins (Gitea Branch Source / multibranch): PRs run the gates, `main` also builds, pushes and signs | PRs can be blocked before merge |
| CI per project | BelleShop: Jenkins. Later projects: Gitea Actions, with a runner on its own VM, enabled for trusted repos only | Learn both. The runner executes PR code: it never shares a host with anything else (2026-10-24 postmortem) |
| TLS | Caddy `tls internal` on each host, as for gitea; roots trusted by the Mac, Jenkins and containerd on the nodes | Replaced by one lab CA in Week 6 |

## Not now

- Gitea Actions and its runner: with the first project after BelleShop.
- One lab CA instead of a Caddy CA per host: Week 6.
- Kyverno signature checks: Week 4. Week 3 only produces the signatures.

## Consequences

- Week 3 takes about two weeks. ROADMAP Week 3 now includes the rebuild.
- The old Jenkins SSH key in `tunsadmin`'s `authorized_keys` on the k8s nodes is removed, and with it the
  nodes' last inbound path from CI.
- `k8s/*.yaml` in BelleShop switch from `belleshop-*:latest` to `registry.home.arpa/belleshop/...@sha256:...`.
  The nodes need the registry's CA and the `k8s-pull` Secret before the first such sync.
- Four more VMs to patch and back up: all join the baseline role and the PBS job.
- RAM: about +16 GB new, −12 GB from the old VMs. tuns had 15 GB free on 2026-10-29.

## Rollout

| Step | Status |
|---|---|
| Shut down 104-106, `onboot 0` | Done 2026-10-29; delete after 2026-11-28 |
| `nexus` + registry, nodes pull a test image | Done: owner accepted the CE EULA (2026-10-29, `nexus_accept_ce_eula`); tags immutable; `k8s-pull` cannot push (403); nodes pull via the CRI resolver (`use_local_image_pull = true`) |
| `sonarqube` | Done: project `belleshop`, user `jenkins` (browse + scan on that project only), token copied to Jenkins |
| `jenkins` + `ci-agent` | Done: JCasC, 0 executors, agent online over WebSocket, gates in `/opt/ci-gates`, all lab CAs trusted (`lab_ca_trust`) |
| `ci/` gates + BelleShop Jenkinsfile | Done. First full green `main` build #4 (2026-10-30). The gates found and blocked: k8s misconfigs (fixed in PR-1), CVEs vendored in pip and in curl/brotli (pip and curl removed from runtime images) |
| Webhook, Gitleaks on PRs, Cosign | Done: Gitea webhook to Jenkins only (`ALLOWED_HOST_LIST`), job via REST API (not JCasC job-dsl: a bad script stopped Jenkins booting), cosign 3 signing config without tlog; signatures + SBOM attestations verified with the public key |
| Proof: PR with a CVE-laden base image blocked | Done 2026-10-30: PR-3 blocked by the Image gate, 92 fixable HIGH/CRITICAL ([screenshot](../evidence/week-03-image-gate-blocked.png)); closed unmerged |

Changes to the decision made during rollout (2026-10-29):

- **No SonarQube webhook.** SonarQube's SSRF guard rejects private webhook targets, and a webhook is a message a build
  on the agent could forge. The scanner waits for the gate instead (`sonar.qualitygate.wait=true`).
- Work split across agents (Antigravity, Cursor, Droid) in separate worktrees, each branch reviewed before merge;
  every merge was then run against the real hosts, which caught one bug per role that `ansible-lint` passed.
- All apt repositories moved to deb822 (`apt_repository` is removed in ansible-core 2.25).
