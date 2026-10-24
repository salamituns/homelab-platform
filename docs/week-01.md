# Week 1: Infrastructure as Code + secure baseline

Dates: 2026-10-23 to 2026-10-24
Outcome: `sectools` (VMID 120) is created by Terraform and hardened by Ansible, entirely from this repo.

---

## 1. Starting point (what was found)

Inventory taken before any changes:

| Host | IP | Role |
|---|---|---|
| `tuns` | 192.168.1.181 | Proxmox VE 9.1 hypervisor (bare metal, 40c / 62G) |
| `Master` | .90 | K8s control plane |
| `WorkerNode1` / `WorkerNode2` | .89 / .84 | K8s workers |
| `JenkinsCICD` | .88 | Jenkins |
| `SonarQuality` | .86 | SonarQube |
| `Nexus` | .87 | Nexus (artifacts / registry) |
| `Tomcat` | .85 | App server |
| `DockerApp` | .92 | Docker host |
| `UbuntuNew` | .83 | **Gitea** (gitea.example.internal via cloudflared + nginx + postgres) |
| `sectools` | .95 | **New in week 1.** DevSecOps tools VM, Terraform-managed |

Commands used to discover this (safe, read-only):

```sh
# Proxmox: VMs, storage, templates
ssh tuns 'pveversion; qm list; pvesm status'
ssh tuns 'qm config 109'                      # inspect a template

# Kubernetes: nodes and what is installed
ssh Master 'kubectl get nodes -o wide'
ssh Master 'kubectl get pods -A --no-headers | awk "{print \$1}" | sort | uniq -c'
ssh Master 'kubectl get applications -A'     # ArgoCD apps

# What is a VM actually running? (never assume a VM is idle)
ssh UbuntuNew 'systemctl list-units --type=service --state=running'
ssh UbuntuNew 'sudo ss -tlnp'                 # listening ports and owning processes
```

Findings that shaped the work:
- Every VM was built by hand. Nothing was reproducible.
- Template 109 is cloud-init ready (DHCP, `tunsadmin`, SSH key). Template 110 has a stale IP
  (10.2.0.110/21, not on the LAN), so it is **not used**.
- The legacy role `~/ansible/roles/base-hardening` on `tuns` replaced `/etc/ssh/sshd_config`
  wholesale and **dropped the `Include` line**, so any `sshd_config.d/` drop-in was silently ignored.

---

## 2. Repo layout

```
homelab-platform/
├── .envrc                  # Proxmox endpoint + token (gitignored, chmod 600)
├── .pre-commit-config.yaml # security + lint gates on every commit
├── Makefile                # short commands: plan, apply, baseline, scan
├── ROADMAP.md              # 8-week plan with checkboxes
├── trivy.yaml              # trivy scan config (skips vendored code)
├── scripts/
│   └── bootstrap-proxmox-token.sh   # one-time: create the Terraform identity on Proxmox
├── terraform/proxmox/
│   ├── versions.tf         # Terraform + provider versions, provider config
│   ├── variables.tf        # gateway, DNS, template, SSH keys
│   ├── main.tf             # THE LIST OF VMs (locals.vms). Add a VM here.
│   ├── outputs.tf          # name => IP
│   ├── terraform.tfvars    # your SSH public keys (gitignored)
│   └── modules/vm/         # reusable "one VM" module
├── ansible/
│   ├── ansible.cfg         # inventory, roles and collections paths
│   ├── requirements.yml    # Ansible collections
│   ├── inventory/hosts.yml # all hosts, grouped
│   ├── inventory/host_vars/UbuntuNew.yml   # Gitea override: also allow user "git"
│   ├── playbooks/baseline.yml
│   └── roles/baseline/     # packages, auto-updates, fail2ban, auditd, SSH hardening
└── docs/
    ├── week-01.md          # this file
    ├── runbooks/rebuild-vm.md
    └── adr/0001-terraform-proxmox-greenfield-first.md
```

**Who owns what:**
- Terraform owns *whether a VM exists* and its size (CPU, RAM, disk, IP).
- Ansible owns *what is configured inside it* (packages, SSH, services).
- (Week 2) ArgoCD owns *what runs on Kubernetes*.

---

## 3. One-time workstation setup

```sh
# Tools (each installed separately: one bad name aborts a combined brew install)
brew install terraform ansible ansible-lint pre-commit gitleaks trivy
brew install terraform-linters/tap/tflint

cd ~/homelab-platform

# Ansible collections go INSIDE the repo (ansible/collections, gitignored).
# --force is needed because Homebrew's ansible bundles its own copies and galaxy skips otherwise.
ansible-galaxy collection install -r ansible/requirements.yml -p ansible/collections --force

# Install the git hook so the gates run on every commit
pre-commit install
```

---

## 4. Proxmox identity for Terraform (least privilege)

Ran once: `scripts/bootstrap-proxmox-token.sh`. It creates:

| Object | Purpose |
|---|---|
| Pool `terraform` | All Terraform VMs live here |
| User `terraform@pve` | Terraform's own identity, separate from root in audit logs |
| Role `TerraformProv` on `/pool/terraform` and `/storage/local-lvm` | Create/configure/power/delete VMs **only in the pool**, allocate disk |
| Role `TerraformClone` on `/vms/109` | Clone the template, not modify it |
| `PVESDNUser` on `/sdn/zones/localnetwork/vmbr0` | Attach NICs to the bridge |
| Role `TerraformNodeRead` on `/nodes/tuns` | Read node status |
| API token `terraform@pve!homelab` | Written straight to `.envrc`, never printed |

Verify the blast radius (what can the token see?):

```sh
source .envrc
curl -sk -H "Authorization: PVEAPIToken=$PROXMOX_VE_API_TOKEN" \
  https://192.168.1.181:8006/api2/json/cluster/resources?type=vm \
  | python3 -c 'import sys,json; print(sorted(v["vmid"] for v in json.load(sys.stdin)["data"]))'
# Expected: [109] plus Terraform-created VMs (e.g. 120). Never 100-111.
```

Undo everything (if ever needed):

```sh
ssh tuns 'pveum user delete terraform@pve; pveum role delete TerraformProv;
          pveum role delete TerraformClone; pveum role delete TerraformNodeRead;
          pveum pool delete terraform'
```

Rotate the token (do this if it ever leaks):

The bootstrap script creates the pool, roles and user too, so it fails if they already exist.
To rotate **only** the token:

```sh
ssh tuns 'pveum user token remove terraform@pve homelab'
ssh tuns 'pveum user token add terraform@pve homelab --privsep 0 --output-format json'
# Copy "value" from the output into .envrc as: terraform@pve!homelab=<value>
chmod 600 .envrc
```

---

## 5. Terraform: build a VM

```sh
cd ~/homelab-platform
source .envrc          # every new terminal: loads the Proxmox token

make init              # once, or after changing providers/modules
make plan              # writes the plan to terraform/proxmox/tfplan
make apply             # applies EXACTLY the saved plan
```

How to read a plan, in order:
1. The summary line: `Plan: X to add, Y to change, Z to destroy`. **Z must be what you expect** (usually 0).
2. `-/+` means destroy-and-recreate (dangerous). `~` means change in place. `+` means create.
3. Check values you care about: IP, disk size, CPU, keys.

Add a new VM: add an entry to `locals.vms` in `terraform/proxmox/main.tf`, then `make plan`.

Useful extra commands:

```sh
terraform -chdir=terraform/proxmox state list      # what Terraform manages
terraform -chdir=terraform/proxmox output          # name => IP
terraform -chdir=terraform/proxmox destroy         # removes ALL managed VMs (asks first)
terraform -chdir=terraform/proxmox destroy -target='module.vm["sectools"]'   # just one
```

Note: `apply` took about 4 minutes. Most of that is the provider waiting for the
qemu guest agent inside the VM to report its IP (proof the VM actually booted).

---

## 6. Trusting a new VM's SSH host key (do not just type "yes")

A new VM generates a new host key. Verify it through a second, trusted channel (the hypervisor),
then add it to `known_hosts`:

```sh
IP=192.168.1.95; VMID=120

# Key as seen over the network
ssh-keyscan -t ed25519 $IP 2>/dev/null | grep -v '^#' | ssh-keygen -lf -

# Key as seen from INSIDE the VM, via Proxmox's guest agent
ssh tuns "qm guest exec $VMID -- cat /etc/ssh/ssh_host_ed25519_key.pub" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["out-data"].strip())' | ssh-keygen -lf -

# The two SHA256 fingerprints must be identical. Then:
ssh-keyscan -t ed25519 $IP 2>/dev/null | grep -v '^#' >> ~/.ssh/known_hosts
```

Compare **fingerprints**, not raw text. The two outputs are formatted differently (the first has the
IP in front, the second has a comment at the end).

---

## 7. Ansible: harden a VM

Always dry-run first, then apply, then run again to prove idempotency:

```sh
cd ~/homelab-platform

# Wait for cloud-init on a NEW VM, or apt locks will collide with Ansible
ssh tunsadmin@192.168.1.95 'cloud-init status --wait'

make baseline-check HOST=sectools   # --check --diff: shows changes, changes nothing
make baseline HOST=sectools         # apply
make baseline HOST=sectools         # again: expect changed=0
```

What the `baseline` role does:

| Task | Effect |
|---|---|
| Install packages | qemu-guest-agent, unattended-upgrades, fail2ban, chrony, curl, htop, auditd |
| Timezone | America/Chicago |
| Enable services | All of the above started and enabled at boot |
| Auto security updates | `/etc/apt/apt.conf.d/20auto-upgrades` |
| SSH drop-in | `/etc/ssh/sshd_config.d/10-hardening.conf` (validated with `sshd -t` before going live) |
| SSH Include | Ensures line 1 of `sshd_config` is `Include /etc/ssh/sshd_config.d/*.conf` |

SSH settings and why:

| Setting | Why |
|---|---|
| `PermitRootLogin no` | Root is the first account attackers try |
| `PasswordAuthentication no` + `KbdInteractiveAuthentication no` | Keys only. Both are needed: the second is another password path |
| `MaxAuthTries 3`, `LoginGraceTime 30` | Slows brute force (fail2ban bans after that) |
| `X11Forwarding no`, `AllowAgentForwarding no` | Removes features servers do not need; agent forwarding lets a compromised box use your keys |
| `ClientAliveInterval 300` / `CountMax 2` | Drops dead sessions after about 10 minutes |
| `LogLevel VERBOSE` | Logs which key fingerprint logged in (needed for incident work) |
| `AllowUsers` | Only listed users can SSH in. Default `tunsadmin`; `UbuntuNew` also allows `git` (Gitea) |

Why `10-` in the file name: Ubuntu reads drop-ins in name order and, for most options, the **first**
value wins. `10-hardening.conf` loads before cloud-init's `50-cloud-init.conf`, which sets
`PasswordAuthentication yes`.

Verify hardening actually took effect (do not trust "changed: ok"):

```sh
H=tunsadmin@192.168.1.95
ssh $H echo OK                                                    # key login works
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive $H true
#   expect: Permission denied (publickey).
ssh root@192.168.1.95 true                                        # expect: Permission denied
ssh $H 'sudo sshd -T | grep -iE "^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowusers|allowagentforwarding) "'
ssh $H 'systemctl is-active fail2ban chrony auditd qemu-guest-agent unattended-upgrades'
```

`sshd -T` prints the **effective** config after all files are merged. It is the source of truth.

Applied so far: `UbuntuNew` (2026-10-24), `sectools` (2026-10-24).

---

## 8. Security gates (run before every commit, and automatically on commit)

```sh
make scan        # = pre-commit run --all-files
```

| Gate | Catches |
|---|---|
| gitleaks | Secrets/tokens in files |
| terraform fmt / validate | Formatting and invalid config |
| tflint | Terraform best-practice issues (e.g. missing version pins in modules) |
| trivy (config) | Insecure infrastructure settings |
| ansible-lint (production profile) | Ansible mistakes and bad practice |
| detect-private-key, check-yaml, whitespace | Hygiene |

---

## 9. Problems hit and how they were fixed (good interview stories)

| Problem | Cause | Fix |
|---|---|---|
| `brew install a b c ...` installed nothing | One bad formula name aborts the whole command (still exit 0) | Install each tool separately |
| ansible-lint: `couldn't resolve community.general.timezone` | Homebrew's ansible and ansible-lint have separate Python envs | Collections installed into the repo, `collections_path` in `ansible.cfg` |
| Linters scanned thousands of vendored files | Collections live under `ansible/` | `ansible/.ansible-lint` and `trivy.yaml` exclude them |
| tflint failed on the module | Child modules need their own version constraints | Added `required_version` and provider `version` to the module |
| Ansible error: `community.general.yaml` callback removed | `stdout_callback = yaml` is gone in current Ansible | `callback_result_format = yaml` |
| Dry run failed on chrony/auditd services | In `--check`, packages are not really installed, so services do not exist | `ignore_errors: "{{ ansible_check_mode }}"` on that task only |
| SSH drop-in would have done nothing on old VMs | Legacy role removed the `Include` line | New task restores it, **after** the drop-in exists |
| Hardening would have locked out Gitea's `git` user | `UbuntuNew` is the Gitea server, not idle | `inventory/host_vars/UbuntuNew.yml` allows `git` |
| Rebuild drill: `(stdin) is not a public key file`, then `Connection refused` | `make apply` returns when the guest agent answers, before cloud-init and sshd are up | `scripts/trust-host-key.sh` waits for cloud-init + port 22, and only trusts on a fingerprint match |
| `trust-host-key.sh` hung on old VMs | Their cloud-init reports `status: disabled`, never `done` | Accept `done` or `disabled` |
| Proxmox token creation blocked by Claude Code's auto-mode safety check | Creating a privileged credential needs human action | Packaged as `scripts/bootstrap-proxmox-token.sh`, run by you |

Lessons:
1. **Record before-state, then change, then compare.** It caught the `git` user lockout.
2. **"Applied" is not "working".** Verify the effective state (`sshd -T`), not the task status.
3. **Scope credentials to their blast radius.** The token cannot see the hand-built VMs.

---

## 10. Still to do

- [x] Week 1 proof: destroyed and rebuilt `sectools` from code (2026-10-24), all checks passed
- [x] Push this repo to Gitea (private, source of truth) with a push-mirror to public GitHub
- [ ] Retire `~/ansible` on `tuns` (its sshd template removes the `Include` line). Port its useful
      parts (sysctl hardening, ufw, internal DNS) into this repo in week 2
- [ ] Roll the baseline out to the remaining VMs, one at a time, dry run first

---

## 11. Source control: Gitea + GitHub mirror

```
Mac --git push--> Gitea (private, source of truth) --push-mirror--> GitHub (public portfolio)
```

- Gitea repo: `<gitea-org>/homelab-platform` (private)
- GitHub repo: https://github.com/salamituns/homelab-platform (public, read-only copy)
- Mirror: Gitea, Settings, Mirror Settings. Syncs on every push, plus every 8h.
  Auth: GitHub fine-grained token scoped to this one repo, Contents read/write, **expires in 90 days**.

Push from the Mac (token from `.envrc`, never stored in `.git/config`):

```sh
source .envrc
git -c credential.helper= -c http.extraHeader="Authorization: token $GITEA_TOKEN" push
```

Before the repo went public, the Gitea domain was scrubbed from **all history** with
`git filter-repo --replace-text` (cleaning only the latest files would have left it in old commits).
Audit the public copy any time:

```sh
git clone https://github.com/salamituns/homelab-platform.git /tmp/audit && cd /tmp/audit
git log -p --all | grep -ciE 'gitea\.[a-z]+\.com'   # expect 0
gitleaks git . --no-banner                           # expect: no leaks found
```

Gitea token scopes learned the hard way: creating a repo under a user needs `write:user`;
pushing and managing mirrors needs only `write:repository`. The repo was created in the UI instead,
so the token stays at `write:repository` + `read:user`.
