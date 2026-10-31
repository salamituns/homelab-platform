# Role: `jenkins`

Deploys the rebuilt Jenkins **controller** on `jenkins` (`192.168.1.88`) per
[ADR 0011](../../../docs/adr/0011-ci-platform-rebuild.md). Builds do not run here
(`numExecutors: 0`); the inbound agent is role `ci_agent`.

## What it does

1. **Java + apt (`tasks/install.yml`)**
   - Installs Ubuntu `openjdk-21-jre-headless` and `fontconfig` (Jenkins 2.580.x
     documents JDK 21).
   - Adds the official `debian-stable` apt repo with `jenkins.io-2026.key` as a
     signed keyring (same pattern as `roles/caddy`).
   - Installs `jenkins=2.580.2` and **holds** the package.
   - Stops the service immediately so the setup wizard cannot race JCasC.
2. **Plugins (`tasks/plugins.yml`)**
   - Downloads pinned `jenkins-plugin-manager` 2.15.0 (SHA-256 from the GitHub
     release checksum file).
   - Installs the exact set in `templates/plugins.txt.j2` into
     `/var/lib/jenkins/plugins`.
3. **JCasC (`tasks/config.yml`)**
   - Generates an admin password on the host into
     `/etc/jenkins/secrets/admin-password` (`0640 root:jenkins`) and copies it to
     `/root/jenkins-initial-admin-password` (`0600`).
   - Writes `/var/lib/jenkins/casc/jenkins.yaml`: local realm (no sign-up),
     matrix authorization (admin administers, authenticated read, anonymous
     nothing), CSRF crumbs on, plain-text markup, URL
     `https://jenkins.home.arpa/`, agent TCP port **disabled**, one permanent
     node `ci-agent` (label `docker`, inbound WebSocket).
   - systemd drop-in: listen `127.0.0.1:8080`, setup wizard off,
     `CASC_JENKINS_CONFIG=/var/lib/jenkins/casc`.
4. **Secrets + extra JCasC (`tasks/secrets.yml`, `tasks/casc_extra.yml`)**
   - Copies optional secrets into `/etc/jenkins/secrets/<name>` (`0640
     root:jenkins`) from Nexus, SonarQube, or gitignored `private/` files.
   - Missing sources are **skipped** (debug warning), never invented.
   - Writes sibling YAML only for secrets that exist: `credentials.yaml`,
     `sonar.yaml`, `gitea.yaml`, `jobs.yaml`. A credential whose file is absent
     is omitted so JCasC does not `${readFile}` a missing path.

Caddy (playbook, after this role) terminates TLS. The Caddy root CA is fetched
to `ansible/files/ca/jenkins-caddy-root.crt` by `roles/caddy`.

## Versions (checked 2026-10-29)

| Component | Version | Checksum / pin source |
|---|---|---|
| Jenkins LTS | 2.580.2 | `debian-stable` (`get.jenkins.io/debian-stable/`, 2026-10-27) |
| plugin-manager jar | 2.15.0 | GitHub `jenkins-plugin-manager-2.15.0.jar.sha256` |
| Plugins | see `defaults/main.yml` | LTS update-center; job-dsl removed 2026-10-31 (job comes from REST config.xml) |
| Java | OpenJDK 21 | Ubuntu 24.04 apt (not held; security updates stay on) |

## Secrets the owner must create by hand

The role only **moves** files. Create these before you want the matching
Jenkins credential / job. The playbook still succeeds if they are missing.

| Credential id | Type | Create |
|---|---|---|
| `nexus-ci-push` | username/password (`ci-push`) | Run the Nexus playbook. Password is `/etc/nexus/secrets/ci-push` on `nexus`. |
| `sonarqube-token` | secret text | On SonarQube, create a token for Jenkins and write it to `/etc/sonarqube/secrets/jenkins-token` on `sonarqube` (`0640`). |
| `cosign-key` | secret file `cosign.key` | On the Mac: `cosign generate-key-pair` (passphrase prompted). Move `cosign.key` to `private/cosign.key`. Keep `cosign.pub` for Week 4. |
| `cosign-password` | secret text | Same passphrase, one line, `private/cosign.password`. |
| `gitea-jenkins` | Gitea PAT | In Gitea: Settings → Applications → generate a token (repo + hook). Save as `private/gitea-jenkins.token`. |
| BelleShop owner | extra var | Copy `extra-vars.example.yml` to `private/jenkins.yml` and set `jenkins_belleshop_owner` (the Gitea user/org that owns `BelleShop`). Pass `-e @../private/jenkins.yml`. Never commit that file. |

`private/` is gitignored. Cosign and Gitea files are read from the Ansible controller, not from the Jenkins VM.

Jenkins must trust the Caddy CAs for `gitea.home.arpa` and `sonarqube.home.arpa` (system + JVM) or SCM/Sonar API calls fail. That is outside this role.

## First-run operator steps

1. `cd ~/homelab-platform/ansible && ansible-playbook playbooks/jenkins.yml -e @../private/jenkins.yml`
2. Trust `ansible/files/ca/jenkins-caddy-root.crt` on the Mac.
3. `ssh jenkins 'sudo cat /root/jenkins-initial-admin-password'` and log in at
   `https://jenkins.home.arpa/` as `admin`. Change the password in the UI (JCasC
   will overwrite it on the next run until you stop managing that user, or
   update the secret file).
4. `ssh jenkins 'sudo shred -u /root/jenkins-initial-admin-password'` after it is
   stored somewhere durable. Do **not** shred `/etc/jenkins/secrets/admin-password`
   while JCasC still reads it.

## How to upgrade Jenkins

1. `sudo apt-mark unhold jenkins` is done by setting `dpkg_selections` to
   `install` in a one-off change, or temporarily.
2. Bump `jenkins_version` and re-resolve `jenkins_plugins` against the LTS
   update center. Bump plugin-manager + SHA-256 if needed.
3. Re-run the playbook. `get_url` verifies the plugin-manager jar; apt installs
   the new `jenkins=` version; then hold again.
