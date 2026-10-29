# Runbook: the CI platform (Nexus, SonarQube, Jenkins, agent)

Design: [ADR 0011](../adr/0011-ci-platform-rebuild.md). Roles: `ansible/roles/{nexus,sonarqube,jenkins,ci_agent,lab_ca_trust,containerd_registry}`.
Playbooks: `ansible/playbooks/{nexus,sonarqube,jenkins,k8s-registry-trust}.yml`.
Gates: `ci/gates/README.md`. First draft: 2026-10-29.

## 1. What runs where

Every service binds to `127.0.0.1`. Caddy on `443/tcp` is the only door from the LAN, and UFW
allows it from named clients only. Nothing is exposed to the internet ([entry points](../entry-points.md)).
All four VMs and the Nexus data disk are in the nightly PBS backup (ADR 0006).

| Host | IP | VMID | Size | Service (systemd) | Local port | URL |
|---|---|---|---|---|---|---|
| `nexus` | `192.168.1.87` | 124 | 4c/6 GB + 100 GB data | `nexus` - Nexus Repository CE 3.97.2-02 (bundled JDK) | `127.0.0.1:8081` UI/API, `127.0.0.1:8082` Docker | `https://nexus.home.arpa/` |
| `sonarqube` | `192.168.1.86` | 125 | 2c/4 GB | `sonarqube` - Community Build 26.10 + PostgreSQL 16 | `127.0.0.1:9000` | `https://sonarqube.home.arpa/` (alias `sonar.home.arpa`) |
| `jenkins` | `192.168.1.88` | 126 | 2c/2 GB | `jenkins` - LTS 2.580.2, **0 executors** (controller only) | `127.0.0.1:8080` | `https://jenkins.home.arpa/` |
| `ci-agent` | `192.168.1.93` | 127 | 2c/4 GB/60 GB | `jenkins-agent` + Docker CE (pinned, held) | - (dials out) | - |

- `registry.home.arpa` is Caddy on `nexus` fronting the Docker connector `127.0.0.1:8082`
  (repo `belleshop`, `write_policy: allow_once` — a tag can never be overwritten). Anonymous
  access is off: `ci-push` may push, `k8s-pull` may only pull.
- The three k8s nodes (`Master` `.90`, `WorkerNode1` `.89`, `WorkerNode2` `.84`) trust the
  registry's CA through `roles/containerd_registry` (`/etc/containerd/certs.d/registry.home.arpa/`).
- `ci-agent` connects **inbound** to the controller over WebSocket, so Jenkins holds no SSH key
  on it. Gate scripts are in `/opt/ci-gates`, scanners in `/opt/ci-scanners`.
- JVMs on `jenkins`, `sonarqube` and `ci-agent` trust the lab CAs through `roles/lab_ca_trust`.
  A JVM reads its truststore at start, so that role restarts the named unit when a CA file
  changes (skipped on a first run, when the unit does not exist yet).

## 2. Build or rebuild the whole platform

Order matters: each step consumes something the previous one produces.

| # | Step | Produces for the next steps |
|---|---|---|
| 0 | Terraform VMs + DNS records | The four VMs exist; `*.home.arpa` names resolve |
| 1 | `playbooks/nexus.yml` | `registry.home.arpa` is live; `nexus-caddy-root.crt` is in `ansible/files/ca/`; `ci-push` and `k8s-pull` secrets exist on `nexus` |
| 2 | `playbooks/sonarqube.yml` | The `jenkins` user and its token on `sonarqube` (the Jenkins role reads them over SSH) |
| 3 | `playbooks/jenkins.yml` (both plays) | Controller + agent; `nexus-ci-push` and `sonarqube-token` copied onto `jenkins` |
| 4 | `playbooks/k8s-registry-trust.yml` | The nodes can pull from `registry.home.arpa` |

```sh
cd ~/homelab-platform
source .envrc
make plan && make apply        # VMs 124-127; per-VM rebuild: runbooks/rebuild-vm.md

cd ansible                     # ansible.cfg, inventory and roles_path live here
ansible-playbook playbooks/dns.yml --limit gateway   # a record in dns.yml is NOT live until this runs
ansible-playbook playbooks/nexus.yml --limit nexus
ansible-playbook playbooks/sonarqube.yml --limit sonarqube
ansible-playbook playbooks/jenkins.yml -e @../private/jenkins.yml
ansible-playbook playbooks/k8s-registry-trust.yml
```

Why this order:

- **Nexus first** because everything pulls images through it, and the CA that Nexus' Caddy
  fetches (`files/ca/nexus-caddy-root.crt`) is what the agent, Jenkins and the nodes must trust.
- **SonarQube before Jenkins** because the `jenkins` role copies
  `/etc/sonarqube/secrets/jenkins-token` from the `sonarqube` host. Missing sources are
  skipped with a debug warning, never invented — so Jenkins also runs without SonarQube, just
  without the Sonar credential.
- **Jenkins before the nodes** because step 4 needs Nexus only, but nothing needs the nodes.
- Accept the Nexus EULA on the first start (section 5) or step 1's bootstrap stalls on 403.

The `private/` files (Cosign key/password, Gitea token, BelleShop owner) are optional at build
time. Without them the playbook still succeeds; `gitea.yaml` and `jobs.yaml` are simply not
written (verified 2026-10-29: only `credentials.yaml`, `jenkins.yaml`, `sonar.yaml` exist).

## 3. Where every secret lives

No secret values in this file. 0600/0640 means owner root. Every file is created by a role on
the host itself or by the owner by hand; nothing secret is in git.

| Secret | Lives at (mode) | Created by | Used by |
|---|---|---|---|
| Nexus admin password | `nexus:/root/nexus-admin-password` (0600) | `nexus` role (first-start rotation) | Owner login; later playbook runs. If you change it in the UI, update the file too |
| `ci-push` registry password | `nexus:/etc/nexus/secrets/ci-push` (0600) | `nexus` role (`openssl rand`, on the host) | Copied onto `jenkins:/etc/jenkins/secrets/nexus-ci-push` (0640) -> Jenkins credential `nexus-ci-push` |
| `k8s-pull` registry password | `nexus:/etc/nexus/secrets/k8s-pull` (0600) | `nexus` role | The k8s `imagePullSecret`. Nothing in this repo creates it yet; do it by hand (unverified) |
| SonarQube admin password | `sonarqube:/root/sonarqube-initial-admin-password` (0600) | `sonarqube` role (rotates built-in `admin/admin`) | Owner login, and `tasks/integration.yml` reads it on every run: keep it (change it in the UI = update the file) |
| SonarQube DB password | `sonarqube:/etc/sonarqube/secrets/db_password` (0640 root:sonar) | `sonarqube` role, on the host | `sonar.properties`; handed to `psql` on stdin, never argv |
| SonarQube token for Jenkins | `sonarqube:/etc/sonarqube/secrets/jenkins-token` (0600) | `sonarqube` role (integration) | Copied onto `jenkins:/etc/jenkins/secrets/sonarqube-token` -> JCasC credential |
| SonarQube `jenkins` user's local password | Memory only, random | `sonarqube` role | Nobody — the API demands one, Jenkins uses the token |
| Jenkins admin password | `jenkins:/etc/jenkins/secrets/admin-password` (0640 root:jenkins) + `/root/jenkins-initial-admin-password` (0600) | `jenkins` role | JCasC local realm; owner login. Do not shred the first while JCasC reads it |
| Agent JNLP secret | `ci-agent:/etc/jenkins-agent/secret` (0600) | `ci_agent` role (fetched over loopback on the controller) | agent.jar, via `-secret @file` |
| Cosign private key + password | Mac: `private/cosign.key`, `private/cosign.password` (gitignored) | Owner (`cosign generate-key-pair`) | Copied onto `jenkins:/etc/jenkins/secrets/`; `cosign.pub` goes to the cluster in week 4. Not created yet (2026-10-29) |
| Gitea token for Jenkins | Mac: `private/gitea-jenkins.token` (gitignored) | Owner, in the Gitea UI (repo + hook) | Copied onto `jenkins:/etc/jenkins/secrets/gitea-jenkins`. Not created yet (2026-10-29) |
| BelleShop owner name | Mac: `private/jenkins.yml` (gitignored; not a secret, but the public mirror must not name people) | Owner | `-e @private/jenkins.yml` — without it the BelleShop job is skipped |
| Caddy root CA private keys | `<service-host>:/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.key` | Caddy, on the host | Never leave the host; the public certs are committed in `ansible/files/ca/` |

## 4. Health checks

All verified 2026-10-29 unless marked otherwise.

```sh
cd ~/homelab-platform
curl -q --cacert ansible/files/ca/nexus-caddy-root.crt -sS -o /dev/null -w '%{http_code}\n' https://nexus.home.arpa/
# expected: 200

curl -q --cacert ansible/files/ca/nexus-caddy-root.crt -sS -o /dev/null -w '%{http_code}\n' https://registry.home.arpa/v2/
# expected after the EULA is accepted: 401 with a WWW-Authenticate challenge (anonymous refused).
# 403 with no challenge = the EULA is not accepted yet (section 5).

curl -q --cacert ansible/files/ca/sonarqube-caddy-root.crt -sS https://sonarqube.home.arpa/api/system/status
# expected: {"id":"…","version":"26.10.0.133078","status":"UP"}

curl -q --cacert ansible/files/ca/jenkins-caddy-root.crt -sS -o /dev/null -w '%{http_code}\n' https://jenkins.home.arpa/login
# expected: 200

dig +short @192.168.1.96 registry.home.arpa
# expected: 192.168.1.87

ssh tunsadmin@192.168.1.87 'systemctl is-active nexus caddy'
ssh tunsadmin@192.168.1.86 'systemctl is-active sonarqube caddy postgresql sonarqube-backup.timer'
ssh tunsadmin@192.168.1.88 'systemctl is-active jenkins caddy'
ssh tunsadmin@192.168.1.93 'systemctl is-active jenkins-agent docker'
# expected: "active" for every unit
```

The agent's connection shows in the Jenkins UI under Nodes -> `ci-agent` (unverified — not
checked for this draft). A full pull test (`ctr images pull` on a node) is in the
`containerd_registry` role README; it changes node state, so it is not a health check.

## 5. Common failures (all hit on 2026-10-29)

| Symptom | Cause | Fix |
|---|---|---|
| The playbook succeeds, but every registry request (even as admin) gets `403`, with no `WWW-Authenticate` challenge, so `docker login` fails | Nexus Repository CE serves no repository traffic until its Community EULA is accepted (`GET /service/rest/v1/system/eula` shows `"accepted": false`) | The owner accepts the EULA (a legal decision, not automated without that decision): UI as admin, or the role's EULA variable once set |
| SonarQube never comes up on first run; `web.log` shows a failure writing `extensions/downloads` | The systemd unit is `ProtectSystem=strict`; SonarQube refuses to start if it cannot create its marketplace download dir | Role now creates `/opt/sonarqube-<version>/extensions/downloads` (`sonar:sonar`) and lists it in `ReadWritePaths`. Nothing to do |
| Jenkins does not apply JCasC / fails on boot with an unknown-config-key error | `crumbIssuer.standard.excludeClientFromCrumb` no longer exists in 2.580; JCasC rejects unknown keys instead of ignoring them | Template now uses `crumbIssuer: {standard: {}}`. When upgrading Jenkins, re-check every JCasC key against that release |
| The agent fails to connect; its log shows an unrecognized `-secretFile` option | agent.jar has no `-secretFile`; the supported form reads the file: `-secret @<path>` — also keeps the secret out of `ps` | Template now uses `-secret @{{ ci_agent_secret_path }}` |
| A new record in `dns.yml` (e.g. `registry.home.arpa`) does not resolve from clients, though it is in git | The record list is only data; the DNS server on `gateway` publishes it when its playbook runs | `ansible-playbook playbooks/dns.yml --limit gateway` (see runbooks/internal-dns.md) |
| Creating a SonarQube webhook to Jenkins fails: `Invalid URL: ... site-local ... addresses are not allowed` | SonarQube's SSRF guard rejects private targets, and it stays on. A webhook would also be something a build on the agent could fake ("gate passed") | No webhook at all: the scanner waits for the gate itself (`-Dsonar.qualitygate.wait=true`) and exits non-zero when it fails. The Jenkinsfile has no `waitForQualityGate` stage |
| First run dies at "Restart sonarqube" before the unit exists | An early `flush_handlers` fired a restart queued by the unpack, before `sonarqube.service` was deployed | PostgreSQL is now restarted inline in `database.yml` (no early flush) |
| PostgreSQL role/DB creation failed while the password was visible in `ps` | The password was passed as a `psql` argument (argv is world-readable) | The role pipes it on stdin; check `database.yml` when touching this |
| Jenkins came up with the setup wizard despite JCasC | The packaged unit reads `JAVA_OPTS`; the old `JENKINS_JAVA_OPTIONS` name was silently ignored | The drop-in sets `JAVA_OPTS=... -Djenkins.install.runSetupWizard=false` |
| Nexus unpack produced no `/opt/nexus-<version>/bin/nexus` on first run | `unarchive`'s `include` used a glob; tar matches globs literally, so nothing extracted | `include:` names the exact program directory. Same trap for any future tar member filter |

## 6. Upgrading a pinned version

Every pin and its SHA-256 live in the role's `defaults/main.yml`, bumped together. The
checksum comes from the vendor file named in the comment next to it. When in doubt, look at
the checksum source, not the value.

| Component | Pin lives in | Checksum source |
|---|---|---|
| Nexus CE | `roles/nexus/defaults/main.yml` (`nexus_version` + `nexus_sha256`) | `<download url>.sha256` next to the archive on download.sonatype.com |
| SonarQube | `roles/sonarqube/defaults/main.yml` (`sonarqube_version` + `sonarqube_sha256`) | `.../sonarqube-<version>.zip.sha256` on binaries.sonarsource.com |
| Jenkins LTS | `roles/jenkins/defaults/main.yml` (`jenkins_version`, held by apt) | `debian-stable` apt repo |
| Jenkins plugins | same file (`jenkins_plugins`, `id:`/`ver:` pairs) | LTS update center; re-resolve after a core bump |
| plugin-manager jar | same file (`jenkins_plugin_manager_version` + `_sha256`) | GitHub release `.sha256` |
| Docker CE / containerd.io | `roles/ci_agent/defaults/main.yml` (exact apt versions, then held) | download.docker.com `noble/pool/stable` listing |
| Trivy / Syft / Cosign / Gitleaks | same file (`*_version` + `*_sha256`) | each vendor's release `checksums.txt` |

Recipe, same for all: bump version + checksum together, then:

```sh
cd ~/homelab-platform/ansible
ansible-playbook playbooks/<service>.yml --limit <host> --check --diff
ansible-playbook playbooks/<service>.yml --limit <host>
```

Then the health checks in section 4. Extra steps per service:

- **Nexus:** the old `/opt/nexus-<old>` directory stays; the symlink flips back for rollback.
- **SonarQube:** if `/api/system/status` reports `DB_MIGRATION_NEEDED`, answer the setup
  prompt at `https://sonarqube.home.arpa/setup` (the role README has the API call).
- **Jenkins:** unhold (`apt-mark unhold jenkins`) is done by the role's `dpkg_selections`
  change during the run; bump `jenkins_version`, re-resolve the plugin list, re-run.
- **Agent scanners:** versions are in `/opt/ci-scanners/<tool>-<version>`; an old version is
  not removed until you delete it, so gates can run during the switch.
