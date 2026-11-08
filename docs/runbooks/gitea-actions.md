# Runbook: Gitea Actions runner

Design: [ADR 0019](../adr/0019-internal-developer-platform.md) D4. Role:
[`ansible/roles/gitea_runner`](../../ansible/roles/gitea_runner). Playbook:
[`ansible/playbooks/gitea-runner.yml`](../../ansible/playbooks/gitea-runner.yml).
VM: `gitea-runner` (VMID 129, `192.168.1.94`, 2c/4 GB/60 GB, Terraform `tags = ["ci"]`).
First draft: 2026-11-07. Owner apply pending.

## 1. What it is

A dedicated build VM that runs Gitea Actions jobs. The runner is the official
`gitea-runner` binary (formerly `act_runner`, renamed at v1.0), pinned per release with its
SHA-256 from the release `checksums.txt`. It polls `https://gitea.home.arpa/` outbound and
accepts no inbound connections beyond SSH (UFW default-deny). Each job runs as a Docker
container (Docker CE 29.9.2 / containerd 2.4.2-3, pinned and held, same engine as `ci-agent`)
started through `/run/docker.sock`; nothing publishes a port. One job at a time
(`capacity: 1`).

Gitea side: `[actions] ENABLED = true` and `DEFAULT_ACTIONS_URL = self`
(`roles/gitea/templates/app.ini.j2`), so a relative `uses:` resolves against this Gitea
instead of github.com. 1.27 supports only `github` | `self`; a workflow can still pin a full
URL to a specific mirrored action repo.

## 2. Security model

- **The runner only ever builds Gitea-hosted repos - the pull mirrors of the app repos
  (ADR 0019 D3) - never a public GitHub repo.** A public repo's workflows would run
  `uses:` code from wherever it points, on this lab's network.
- The VM holds **no Gitea admin credential, no cluster credential and no Nexus identity**.
  The only credential on it is the runner registration file
  (`/var/lib/gitea-runner/.runner`, 0600, owner `gitea-runner`), which is exactly what its
  holder can use: accept jobs as this runner.
- Jobs are containerized, unprivileged, no host volume mounts, one bridge network per job
  (`container.valid_volumes: []`, `privileged: false`). The runner user is in the `docker`
  group - the reason this is its own VM, same reasoning as `ci-agent` (ADR 0011): a job that
  can reach Docker cannot also reach any controller credential.
- Gitea's UFW admits the runner's IP (`192.168.1.94`) on 443; Gitea has no inbound path to
  the runner.
- The cache server is off: it binds a listening socket that nothing needs yet (and UFW
  blocks inbound anyway).

## 3. Owner steps: the registration token

Registration needs a token Gitea only hands to a logged-in admin; it can register any number
of runners, so it must not outlive its use. The playbook never creates or prints it.

1. Enable Actions and admit the runner (once, from this repo's branch):
   ```sh
   cd ~/wt-p0-runner/ansible
   ansible-playbook playbooks/gitea.yml --limit gitea
   ```
2. In the Gitea UI as admin: *Site Administration → Actions → Runners → Create new
   registration token* (an org- or repo-scoped token works too if the runner should only
   serve one scope; scope it as small as you can).
3. Place the token on the runner VM, owned by the runner user, 0600, over SSH:
   ```sh
   ssh gitea-runner 'sudo install -o gitea-runner -g gitea-runner -m 0600 /dev/stdin /etc/gitea-runner/registration.token' <<< 'PASTE-TOKEN'
   ```
   (The file must exist before the playbook run; the directory `/etc/gitea-runner` is
   created by the role, so run the playbook once before this step.)
4. Run the runner playbook; it registers with `--token-file` (never argv), then
   `shred -u` deletes the token on success:
   ```sh
   ansible-playbook playbooks/gitea-runner.yml
   ```
5. Verify in the Gitea UI (*Site Administration → Actions → Runners*): one runner named
   `gitea-runner`, label `ubuntu-24.04`, status idle. On the VM:
   `ssh gitea-runner 'systemctl is-active gitea-runner'`.

A run without the token and without prior registration changes nothing else and prints the
owner step. Re-registration (new token, e.g. after a token reset) simply overwrites
`.runner`.

## 4. Build order (new lab from scratch)

`playbooks/gitea.yml` before `gitea-runner.yml` (Actions must be enabled and the runner IP
admitted). The VM comes from Terraform (`gitea-runner`, VMID 129); trust its SSH host key
with `scripts/trust-host-key.sh 192.168.1.94 129` before the first Ansible run. DNS
(`gitea-runner.home.arpa`) goes live when `playbooks/dns.yml` runs on `gateway`.

## 5. Job label image

`runs-on: ubuntu-24.04` runs in `gitea/runner-images:ubuntu-24.04` pulled from
`docker.gitea.com` (Gitea's official registry mirror). It does **not** come from
`registry.home.arpa`: the Nexus `dockerhub` proxy serves `library/*` only, everything on
Nexus needs auth, and this VM has no Nexus identity by design (sharing `k8s-pull` with an
untrusted-build host would leak the cluster's pull credential). Per-app job images from the
per-app Nexus repos are the intended later package.

**Known limitation:** the generic job image does not trust the lab's Caddy root CA, so a
plain `actions/checkout` against `gitea.home.arpa` fails TLS verification *inside the job
container* (the runner process itself is fine). Until per-app job images (built through the
platform, embedding the lab CA) exist, workflows must either mount the CA themselves or pin
`uses:` to mirrored action repos with full URLs. See the role README.

## 6. Upgrading the runner

Bump `gitea_runner_version` + `gitea_runner_sha256` together (re-read the release
`checksums.txt` at `https://gitea.com/gitea/runner/releases`), then re-run the playbook:
`get_url` swaps the binary on checksum match and the handler restarts the daemon. The
`.runner` registration is tied to Gitea, not the binary, and survives upgrades.

## 7. Removing the runner

Delete it in the Gitea runner settings (revokes the registration), then the VM:
`terraform destroy -target='module.vm["gitea-runner"]'` and revert the DNS record.
