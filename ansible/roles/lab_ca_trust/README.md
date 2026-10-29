# Role: `lab_ca_trust`

Makes a host trust the lab's internal CAs: the Caddy `tls internal` root certificates that
front `*.home.arpa` with TLS. Each service's `caddy` role fetches its root to
`ansible/files/ca/<host>-caddy-root.crt` (gitea, nexus, sonarqube, jenkins, sectools); this
role installs the ones a given client actually talks to, from the `lab_ca_trust_cas` list in
its host_vars.

## What It Does

1. Installs `ca-certificates-java`, so the JVM truststore (`/etc/ssl/certs/java/cacerts`) is
   rebuilt whenever the system store changes. Its hook runs inside `update-ca-certificates`.
2. Fails with a clear message if a listed CA file is missing on the controller (the service
   host's playbook has to have fetched it first).
3. Copies each listed CA to `/usr/local/share/ca-certificates/lab/<name>-caddy-root.crt` (0644)
   and runs `update-ca-certificates` through a handler. Verified against the Ubuntu 24.04
   script: it scans `/usr/local/share/ca-certificates` **recursively**, so the `lab/`
   subdirectory is picked up, and the `jks-keystore` hook refreshes the JVM truststore.
   Result: curl, git, Docker CLI addons, Go scanners and Java all trust the same CAs.
4. Flushes its handlers immediately, so later roles in the same play already run against a
   host that trusts the CAs (`ci_agent` downloads `agent.jar` from `jenkins.home.arpa`).

Who trusts whom (set in `ansible/inventory/host_vars/`):

| Host | `lab_ca_trust_cas` | Why |
|---|---|---|
| `ci-agent` | gitea, nexus, sonarqube, jenkins | git clone from gitea; cosign/trivy reach registry.home.arpa outside Docker; scanner uploads to sonarqube; agent connects to jenkins |
| `jenkins` | gitea, sonarqube | branch scanning against gitea; quality-gate API on sonarqube |
| `sonarqube` | jenkins | POSTs the quality-gate webhook to jenkins |

## Java Services Must Be Restarted After a CA Change

A JVM reads its truststore once, at start. When a CA file changes, the role restarts the
service named in `lab_ca_trust_java_service` (`jenkins`, `sonarqube`, `jenkins-agent` on
`ci-agent`). On a first run the service is not installed yet, so the restart is skipped
(the service starts later in the play, already trusting the new CAs). Note that ci-agent's
Docker daemon is handled separately: `roles/ci_agent/tasks/registry.yml` copies the Nexus
CA to `/etc/docker/certs.d/registry.home.arpa/ca.crt`, because dockerd reads only that
directory, and restarts Docker through its own handler.

## Variables (`defaults/main.yml`)

| Variable | Default | Purpose |
|---|---|---|
| `lab_ca_trust_cas` | `[]` | Names of CA files in `ansible/files/ca/` (without the `-caddy-root.crt` suffix) |
| `lab_ca_trust_java_service` | `""` | systemd unit restarted on CA change; empty = none |
| `lab_ca_trust_ca_dir` | `{{ playbook_dir }}/../files/ca` | Controller-side directory of the CA files |
| `lab_ca_trust_ca_suffix` | `-caddy-root.crt` | Filename suffix shared by all fetched CAs |
| `lab_ca_trust_dest_dir` | `/usr/local/share/ca-certificates/lab` | On-host directory scanned by `update-ca-certificates` |

## Usage

Not run standalone; included by `playbooks/jenkins.yml` (both plays) and
`playbooks/sonarqube.yml`, right after `baseline`:

```yaml
roles:
  - baseline
  - lab_ca_trust
  ...
```

No versions to pin: the role only copies certificate files that live in this repo.
