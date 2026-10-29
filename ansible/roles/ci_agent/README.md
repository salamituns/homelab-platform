# Role: `ci_agent`

Inbound Jenkins agent on `ci-agent` (`192.168.1.93`) per
[ADR 0011](../../../docs/adr/0011-ci-platform-rebuild.md). Runs Docker and the
Week 3 scanners. Connects **out** to `https://jenkins.home.arpa/` over WebSocket,
so the controller never stores an SSH key for this host.

Must run **after** the Jenkins controller play: this role downloads `agent.jar`
from the controller. TLS trust for `*.home.arpa` is installed by the
`lab_ca_trust` role (`host_vars/ci-agent.yml`: gitea, nexus, sonarqube, jenkins),
which runs before this one in `playbooks/jenkins.yml`.

## What it does

1. **Docker CE (`tasks/docker.yml`)**
   - Official Docker apt repo, ASCII keyring, pinned `docker-ce` / `cli` /
     `containerd.io` / `docker-buildx-plugin`, then **held**.
   - User `jenkins-agent` is in group `docker`. That group is root-equivalent
     via the daemon socket; isolating the agent on its own VM is the containment
     (not the group itself).
   - Docker listens on the unix socket only. No `-p` publishes, so nothing extra
     is on the LAN (UFW still only allows SSH).
2. **Java (`tasks/trust.yml`)**
   - `openjdk-21-jre-headless` and `ca-certificates-java`, so the JVM truststore
     follows the system store that `lab_ca_trust` updates.
3. **Scanners (`tasks/scanners.yml`)**
   - Pinned trivy, syft, cosign, gitleaks under `/opt/ci-scanners/<ver>/`,
     linked from `/usr/local/bin`. SHA-256 from each vendor's checksums file.
4. **Gates (`tasks/gates.yml`)**
   - Copies `ci/gates/*.sh` to `/opt/ci-gates/` (`root:root` 0755). Pipelines
     call these; the agent user can run them but cannot edit them.
5. **Registry CA (`tasks/registry.yml`)**
   - If `ansible/files/ca/nexus-caddy-root.crt` exists, copy it to
     `/etc/docker/certs.d/registry.home.arpa/ca.crt`. Skip if Nexus is not built
     yet (`ci_agent_registry_hostname` is the directory name).
6. **Agent (`tasks/agent.yml`)**
   - `agent.jar` from `https://jenkins.home.arpa/jnlpJars/agent.jar`.
   - **Secret:** GET `http://127.0.0.1:8080/computer/ci-agent/jenkins-agent.jnlp`
     on the controller (delegated, basic auth as `admin`, `no_log`). The first
     `<argument>` is the JNLP secret. Written to `/etc/jenkins-agent/secret`
     (`0600`, owner `jenkins-agent`).
   - Why JNLP rather than Groovy CLI: it is the endpoint the brief names, needs
     no extra `jenkins-cli.jar`, and the request stays on controller loopback so
     the secret is not fetched over the LAN by the agent itself.
   - `jenkins-agent.service`: `java -jar … -url https://jenkins.home.arpa/ -name
     ci-agent -secretFile … -webSocket -workDir /var/lib/jenkins-agent`,
     `Restart=on-failure`.

## Versions (checked 2026-10-29)

| Component | Version | Checksum source |
|---|---|---|
| Docker CE / CLI | `5:29.9.2-1~ubuntu.24.04~noble` | download.docker.com `noble/pool/stable/amd64` |
| containerd.io | `2.4.2-3~ubuntu.24.04~noble` | same pool |
| docker-buildx-plugin | `0.38.1-1~ubuntu.24.04~noble` | same pool |
| Trivy | 0.76.1 | `trivy_0.76.1_checksums.txt` (`Linux-64bit.tar.gz`) |
| Syft | 1.55.0 | `syft_1.55.0_checksums.txt` (`linux_amd64.tar.gz`) |
| Cosign | 3.1.4 | `cosign_checksums.txt` (`cosign-linux-amd64`) |
| Gitleaks | 8.30.1 | `gitleaks_8.30.1_checksums.txt` (`linux_x64.tar.gz`) |
| Java | OpenJDK 21 | Ubuntu 24.04 apt |

## First-run operator steps

Use the full playbook (both plays):

```sh
cd ~/homelab-platform/ansible
ansible-playbook playbooks/jenkins.yml
```

Confirm the agent is connected: Jenkins UI → Nodes → `ci-agent`.
