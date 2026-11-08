# Role: `gitea_runner`

Gitea Runner (the official Gitea Actions runner, formerly `act_runner`) on `gitea-runner`
(VMID 129, `192.168.1.94`), the dedicated build VM for Gitea Actions per
[ADR 0019](../../../docs/adr/0019-internal-developer-platform.md) D4. Runbook:
[docs/runbooks/gitea-actions.md](../../../docs/runbooks/gitea-actions.md).

## What it does

1. **Docker CE, pinned and held** (`tasks/docker.yml`): same versions as `ci-agent`
   (ADR 0011's isolated-build-host model) - pinned `docker-ce`/`containerd.io` from
   download.docker.com, held against unattended-upgrades, unix socket only. The apt cache is
   always refreshed before the pinned install (the workernode3 stale-cache lesson).
2. **Runner binary, pinned** (`tasks/runner.yml`): `gitea-runner` from
   `https://gitea.com/gitea/runner/releases/download/v<version>/`, SHA-256 verified against
   the release `checksums.txt` (signed as `checksums.txt.sig` since v5.4.0). Version and
   digest are bumped together in `defaults/main.yml`.
3. **Config** (`templates/config.yaml.j2`): one job at a time (`capacity: 1`), no privileged
   containers, no host volumes, no cache server, `runner.insecure: false` (the lab CA is in
   the system store via `lab_ca_trust`). The registration credential is
   `/var/lib/gitea-runner/.runner` (0600, a secret).
4. **Registration**: the OWNER creates a registration token in the Gitea admin UI and places
   it at `/etc/gitea-runner/registration.token` (0600, owner `gitea-runner`). The role
   registers with `--token-file` (never argv), as the runner user, then `shred -u` deletes
   the token on success. A run without token and without registration prints the owner step
   and changes nothing else.
5. **Service** (`templates/gitea-runner.service.j2`): systemd-sandboxed like
   `jenkins-agent.service` (`ProtectSystem=strict`, `NoNewPrivileges=true`, empty
   `CapabilityBoundingSet=`).

## Security model

- The runner executes UNTRUSTED build code, so the VM holds no Gitea admin credential, no
  cluster credential and no Nexus identity. Jobs run as Docker containers through
  `/run/docker.sock`; nothing publishes a port; UFW stays default-deny (SSH only).
- It only ever builds Gitea-hosted repos (the mirrors, ADR 0019 D3) - never a public GitHub
  repo, which would mean running whatever `uses:` points at.
- The runner polls out; Gitea needs no inbound path to it beyond DNS and its 443 allowlist
  entry (`gitea_https_clients` in `roles/gitea`).

## Job label image - why not `registry.home.arpa`

The label is `ubuntu-24.04:docker://docker.gitea.com/runner-images:ubuntu-24.04`, pulled
from Gitea's official registry mirror. It cannot come from `registry.home.arpa` today:

- The Nexus `dockerhub` proxy only serves official images (`/v2/library/*` route) and
  `gitea/runner-images` is not a `library/` image;
- every Nexus repo requires auth (anonymous off), and this VM deliberately has no Nexus
  identity. Giving it `k8s-pull` would share the cluster's pull credential with an
  untrusted-build host.

If a later package wants job images from Nexus (recommended eventually: digest-pinned and
signed), it needs a dedicated read-only Nexus user for the runner plus `/etc/docker/certs.d`
trust, and per-app job images in the app repos - not the generic label image.

## Known limitation: job containers and the lab CA

The default job image does not know the lab's Caddy root CA, so a plain `actions/checkout`
against `gitea.home.arpa` fails TLS verification inside the job container (the runner process
itself is fine - it reads the system store). The intended fix is per-app job images built
through the platform (which embed the lab CA), a later ADR-0019 package. Workflows can also
pin `uses:` with full URLs to mirrored actions in Gitea.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `gitea_runner_version` | `"5.4.1"` | Pinned runner release |
| `gitea_runner_sha256` | `7c4b1b...` | SHA-256 of `gitea-runner-<version>-linux-amd64` (release `checksums.txt`) |
| `gitea_runner_instance_url` | `https://gitea.home.arpa/` | Gitea `ROOT_URL`; job containers dial this name |
| `gitea_runner_labels` | `ubuntu-24.04:docker://docker.gitea.com/runner-images:ubuntu-24.04` | `runs-on` labels |
| `gitea_runner_capacity` | `1` | Concurrent jobs (2 vCPU VM) |
| `gitea_runner_token_path` | `/etc/gitea-runner/registration.token` | The 0600 token file the owner places |
| `gitea_runner_docker_packages` / `_hold` | ci-agent's pins | Docker CE 29.9.2 / containerd 2.4.2-3, held |

## Upgrade

Bump `gitea_runner_version` + `gitea_runner_sha256` together (re-read the release
`checksums.txt`), then re-run `playbooks/gitea-runner.yml`; `get_url` swaps the binary and
the handler restarts the daemon. The `.runner` registration survives (it is tied to Gitea,
not the binary version).
