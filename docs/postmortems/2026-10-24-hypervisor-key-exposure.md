# Postmortem: hypervisor root SSH key exposed on a CI host

- Date found: 2026-10-24
- Severity: **Critical** (path to root on the hypervisor and every VM)
- Status: Contained and rotated: _pending_ (see Action items)
- Evidence of misuse: **none found**
- Author: homelab-platform

## Summary

The private SSH key of `root` on the Proxmox host (`root@tuns`, RSA 4096,
`SHA256:fZPNfUEZXkP0Dl1aNGJ4dfPA/4fS5uZrl4JAEQfg57c`) was stored on the VM `DockerApp`
in `/root/.ssh/id_rsa` and `/home/tunsadmin/.ssh/id_rsa` for about 9 months.

The matching public key was authorized for `root` on the hypervisor and for `tunsadmin`
(passwordless sudo) on all 9 hand-built VMs. `DockerApp` runs a Gitea Actions runner with the
host Docker socket mounted, so any CI job could have become root on `DockerApp`, read the key,
and taken over the hypervisor and every VM.

## Attack path

```
CI job (any repo with Actions enabled)
  -> /var/run/docker.sock mounted into gitea-act-runner
  -> `docker run -v /:/host ...` = root on DockerApp
  -> read /root/.ssh/id_rsa  (root@tuns private key)
  -> ssh root@tuns            (Proxmox host: control of all VMs, storage, backups)
  -> ssh tunsadmin@<any VM> + sudo
```

## Timeline (all times America/Chicago)

| When | What |
|---|---|
| 2026-01-30 | Key pair copied to `DockerApp` (`/root/.ssh`, `/home/tunsadmin/.ssh`) by the legacy `gitea_git_client` Ansible role, which distributes the control node's private key to managed hosts |
| 2026-08-17 15:26-15:48 | 3 SSH logins `DockerApp -> Master` as `tunsadmin` using this key. **Confirmed by the owner as their own activity.** |
| 2026-10-24 | While porting the legacy Ansible project, the reviewing agent was asked to describe `gitea_git_client` and flagged that it distributes a private key |
| 2026-10-24 | Fleet-wide fingerprint scan: key found only on `DockerApp`. Public key authorized on all 9 legacy VMs and on `tuns` |
| 2026-10-24 | Remediation written as code; containment pending owner execution (automation was correctly blocked from deleting key material and creating credentials on the hypervisor without a human) |

## Impact

- **Actual:** none known. No logins into `tuns` from `DockerApp` in available logs. The only
  logins made with the key from `DockerApp` were the owner's own.
- **Potential:** full compromise of the lab (hypervisor root, all VMs, all data).
- Logs only go back so far, and a root-level attacker can edit logs, so "no evidence" is not
  "no compromise". The key is therefore treated as **compromised** and rotated.

## Root cause

1. A legacy Ansible role copied the **control node's private key** to managed hosts so they could
   use git over SSH. Private keys should never leave the machine they were generated on; each host
   that needs git access should get its own deploy key with read-only scope.
2. VM templates 109/110 inject `root@tuns`'s public key through cloud-init, so every VM trusted the
   hypervisor's key, turning one leaked key into fleet-wide access.
3. The CI runner mounts the host Docker socket, which is equivalent to root on that host.

What worked: the Terraform-built VM (`sectools`) was **not** affected, because Terraform sets
SSH keys explicitly instead of inheriting them from the template.

## Remediation

| Step | How | Status |
|---|---|---|
| Delete private key from DockerApp | `ansible/playbooks/incident-2026-10-24-hypervisor-key.yml` (play 1) | Pending |
| Revoke public key on all VMs (and keep it revoked) | `baseline_revoked_ssh_keys` in the baseline role, enforced on every run | Pending |
| Rotate `root@tuns` key; remove old key from `/etc/pve/priv/authorized_keys` | `scripts/rotate-tuns-root-key.sh` | Pending |
| Remove `root@tuns` from templates 109/110 | same script | Pending |
| Verify old fingerprint appears nowhere | fleet fingerprint scan (below) | Pending |

Verification scan (expect no output for any host):

```sh
for h in Master WorkerNode1 WorkerNode2 JenkinsCICD SonarQuality Nexus Tomcat DockerApp UbuntuNew; do
  ssh $h 'sudo bash -c "for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys /root/.ssh/id_* /home/*/.ssh/id_*; do
    [ -f \$f ] && ssh-keygen -lf \$f 2>/dev/null | grep -q fZPNfUEZ && echo \$f; done"' | sed "s/^/$h: /"
done
```

## Action items

- [ ] Run the remediation above (owner, on the home LAN)
- [ ] Week 3: move the CI runner off the host Docker socket (rootless runner or a disposable VM)
- [ ] Week 3: per-host Gitea deploy keys (read-only) instead of shared user keys
- [ ] Do not port `gitea_git_client`; retire the legacy `~/ansible` project on `tuns`
- [ ] Replace the Mac's RSA key with ed25519 (it is root on the hypervisor; see `docs/credentials.md`)
- [ ] Reconsider `fail2ban_ignoreips: 192.168.1.0/24`: a compromised VM can brute-force neighbours unbanned

## Lessons

1. **Private keys never leave the host that created them.** Distribute public keys, never private ones.
2. **One trust anchor per purpose.** The hypervisor's own key should not be authorized on guests.
3. **A Docker socket is root.** Treat any container with it mounted as root on the host.
4. **Infrastructure as code removed the problem where it was used** (`sectools` was clean).
5. **Ask reviewers to describe behavior, not just check that code works.** That is how this was found.
6. **Disclose after fixing.** This document was kept out of the public mirror until remediation was done.
